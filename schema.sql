-- =====================================================================
-- icon4me — Supabase schema (v2)
-- Run once in the Supabase SQL editor (Database > SQL Editor > New query).
--
-- Safe to re-run. It recreates the catalog and keeps every logged workout.
--
-- WHAT CHANGED IN v2
--   * Programs are now upper / lower / core / home / cardio for BOTH users.
--     The old plans (gym, A, B, C, D) are left in the tables untouched so old
--     history still resolves; the app labels them "תוכנית ישנה".
--   * exercises gained `muscles_sec` — the assisting muscles, shown in yellow
--     on the body map.
--   * NEW TABLE app_settings — stores each user's personal customisations:
--     which exercises they deleted, which they added from the pool, and any
--     custom sets/reps. This is what makes a deleted exercise stay deleted
--     across phones.
--   * cardio_log.rpe is no longer written by the app. The column stays so old
--     rows keep their value.
-- =====================================================================

-- ---------- 1. who uses the app ----------
create table if not exists profiles (
  id          text primary key,              -- 'yonatan' | 'itamar'
  name        text not null,
  accent      text not null,
  goal        text,
  week_goal   int  not null default 4,
  created_at  timestamptz not null default now()
);

-- ---------- 2. the training plan (catalog) ----------
create table if not exists programs (
  profile_id  text not null references profiles(id) on delete cascade,
  id          text not null,                 -- 'upper' | 'lower' | 'core' | 'home' | 'cardio'
  label       text not null,
  sub         text,
  icon        text,
  hex         text not null,
  kind        text not null default 'strength',   -- 'strength' | 'cardio'
  sort_order  int  not null default 0,
  primary key (profile_id, id)
);

create table if not exists exercises (
  profile_id   text not null,
  ex_key       text not null,                -- stable slug, e.g. 'upper-01', 'upper-p3'
  program_id   text not null,
  sort_order   int  not null,
  name         text not null,
  target_sets  int  not null,
  target_reps  text not null,                -- '10' | '10 לרגל' | '30 שנ׳'
  weighted     boolean not null default true,
  increment    numeric not null default 2.5, -- how much to add when ready
  equipment    text,
  body_view    text,                         -- 'front' | 'back'
  muscles      text[] not null default '{}', -- primary — red on the body map
  muscles_sec  text[] not null default '{}', -- assisting — yellow on the body map
  in_pool      boolean not null default false, -- true = lives behind "עוד תרגילים"
  cues         text[] not null default '{}',
  primary key (profile_id, ex_key),
  foreign key (profile_id, program_id) references programs(profile_id, id) on delete cascade
);

-- upgrade path for a v1 database that already has data
alter table exercises add column if not exists muscles_sec text[] not null default '{}';
alter table exercises add column if not exists in_pool boolean not null default false;

-- ---------- 3. the weight each person is currently working with ----------
create table if not exists exercise_state (
  profile_id     text not null references profiles(id) on delete cascade,
  ex_key         text not null,
  current_weight numeric,
  updated_at     timestamptz not null default now(),
  primary key (profile_id, ex_key)
);

-- ---------- 4. personal customisations ----------
-- One row per setting key. The app writes k = 'prefs' with a json value:
--   { "hidden": { "upper-04": true },        -- exercises the user removed
--     "added":  { "upper": ["upper-p3"] },   -- exercises pulled in from the pool
--     "plan":   { "upper-01": {"s":5,"r":10} } }  -- custom sets / reps
create table if not exists app_settings (
  profile_id  text not null references profiles(id) on delete cascade,
  k           text not null,
  v           jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now(),
  primary key (profile_id, k)
);

-- ---------- 5. what actually happened ----------
create table if not exists workouts (
  profile_id  text not null references profiles(id) on delete cascade,
  date        date not null,
  program_id  text not null,
  note        text default '',
  created_at  timestamptz not null default now(),
  primary key (profile_id, date, program_id)
);

create table if not exists workout_sets (
  profile_id  text not null,
  date        date not null,
  program_id  text not null,
  ex_key      text not null,
  set_index   int  not null,                 -- 0-based
  weight      numeric,
  reps        numeric,
  done        boolean not null default false,
  primary key (profile_id, date, program_id, ex_key, set_index),
  foreign key (profile_id, date, program_id) references workouts(profile_id, date, program_id) on delete cascade
);

create table if not exists cardio_state (
  profile_id  text not null references profiles(id) on delete cascade,
  kind        text not null,
  stage       int  not null default 0,
  primary key (profile_id, kind)
);

create table if not exists cardio_log (
  id          bigint generated always as identity primary key,
  profile_id  text not null references profiles(id) on delete cascade,
  kind        text not null,
  date        date not null,
  minutes     numeric not null,
  km          numeric,
  rpe         text not null default 'ok',    -- legacy, no longer written
  created_at  timestamptz not null default now()
);

create table if not exists daily_log (
  profile_id  text not null references profiles(id) on delete cascade,
  date        date not null,
  steps       int,
  body_weight numeric,
  primary key (profile_id, date)
);

create index if not exists idx_sets_profile_date   on workout_sets (profile_id, date);
create index if not exists idx_sets_profile_ex     on workout_sets (profile_id, ex_key);
create index if not exists idx_cardio_profile_date on cardio_log (profile_id, date);

-- ---------- 6. handy views ----------
-- one row per training day: feeds the month calendar
create or replace view v_training_days as
  select profile_id, date, program_id, 'strength' as kind,
         count(*) filter (where done) as sets_done,
         coalesce(sum(weight * reps) filter (where done), 0) as volume_kg
  from workout_sets group by profile_id, date, program_id
  having count(*) filter (where done) > 0
  union all
  select profile_id, date, kind as program_id, 'cardio' as kind, 1, 0 from cardio_log;

-- best estimated 1RM per exercise over time (Epley)
create or replace view v_exercise_progress as
  select profile_id, ex_key, date,
         max(weight * (1 + reps / 30.0)) as est_1rm,
         max(weight) as top_weight,
         coalesce(sum(weight * reps), 0) as volume_kg
  from workout_sets where done and weight > 0 and reps > 0
  group by profile_id, ex_key, date;

-- weekly summary per person
create or replace view v_week_summary as
  select profile_id,
         date_trunc('week', date)::date as week_start,
         count(distinct date) as training_days,
         count(*) filter (where done) as sets_done,
         coalesce(sum(weight * reps) filter (where done), 0) as volume_kg
  from workout_sets group by profile_id, date_trunc('week', date);

-- ---------- 7. row level security ----------
-- The app has no login: both phones use the public anon key. These policies
-- keep exactly these tables reachable with that key and nothing else.
alter table profiles       enable row level security;
alter table programs       enable row level security;
alter table exercises      enable row level security;
alter table exercise_state enable row level security;
alter table app_settings   enable row level security;
alter table workouts       enable row level security;
alter table workout_sets   enable row level security;
alter table cardio_state   enable row level security;
alter table cardio_log     enable row level security;
alter table daily_log      enable row level security;

do $$
declare t text;
begin
  foreach t in array array['profiles','programs','exercises','exercise_state','app_settings',
                           'workouts','workout_sets','cardio_state','cardio_log','daily_log']
  loop
    execute format('drop policy if exists anon_read on %I', t);
    execute format('drop policy if exists anon_write on %I', t);
    execute format('create policy anon_read  on %I for select to anon using (true)', t);
    execute format('create policy anon_write on %I for all    to anon using (true) with check (true)', t);
  end loop;
end $$;

-- =====================================================================
-- 8. seed: the two profiles and their training plans
--    Generated from catalog.py — edit there, not here.
-- =====================================================================


-- ---------- יונתן ----------
insert into profiles (id, name, accent, goal, week_goal) values
  ('yonatan', 'יונתן', '#5EE7FF', 'ירידה בשומן + עלייה במסת שריר', 4)
  on conflict (id) do update set name=excluded.name, accent=excluded.accent,
    goal=excluded.goal, week_goal=excluded.week_goal;
insert into programs (profile_id, id, label, sub, icon, hex, kind, sort_order) values
  ('yonatan', 'upper', 'חדר כושר · עליון', 'פלג גוף עליון', '🏋️', '#FF4D6D', 'strength', 0),
  ('yonatan', 'lower', 'חדר כושר · תחתון', 'פלג גוף תחתון', '🦵', '#3DA9FC', 'strength', 1),
  ('yonatan', 'core', 'בטן וליבה', 'ליבה', '🔥', '#FFD23F', 'strength', 2),
  ('yonatan', 'home', 'אימון ביתי', 'בלי ציוד', '🏠', '#2FE6A7', 'strength', 3),
  ('yonatan', 'cardio', 'אירובי וספורט', 'זמן בלבד', '🏃', '#3DA9FC', 'cardio', 4)
  on conflict (profile_id, id) do update set label=excluded.label, sub=excluded.sub,
    icon=excluded.icon, hex=excluded.hex, kind=excluded.kind, sort_order=excluded.sort_order;
insert into exercises (profile_id, ex_key, program_id, sort_order, name, target_sets,
                       target_reps, weighted, increment, equipment, body_view,
                       muscles, muscles_sec, in_pool, cues) values
  ('yonatan', 'upper-01', 'upper', 0, 'לחיצת חזה במכונה (Chest Press Machine)', 3, '10', true, 2.5, 'machine', 'front', ARRAY['chest']::text[], ARRAY['triceps', 'shoulders']::text[], false, ARRAY['מכוונים גובה מושב כך שהידיות בגובה החזה', 'דוחפים קדימה בשליטה, בלי לנעול מרפקים בסוף', 'חוזרים לאט לנקודת ההתחלה — הירידה היא חצי מהתרגיל', 'גב וכתפיים צמודים למשענת לאורך כל התנועה']::text[]),
  ('yonatan', 'upper-02', 'upper', 1, 'פולי עליון (Lat Pulldown)', 3, '10', true, 2.5, 'cable', 'back', ARRAY['lats']::text[], ARRAY['biceps', 'traps']::text[], false, ARRAY['אחיזה מעט רחבה מהכתפיים, אגודל סוגר על המוט', 'מושכים את המרפקים למטה ואחורה, החזה מוביל כלפי מעלה', 'לא מתנופפים אחורה עם הגוף כדי לעזור למשקל', 'עוצרים רגע כשהמוט בגובה הסנטר, וחוזרים בשליטה מלאה']::text[]),
  ('yonatan', 'upper-03', 'upper', 2, 'חתירה בפולי בישיבה (Seated Cable Row)', 3, '10', true, 2.5, 'cable', 'back', ARRAY['lats', 'traps']::text[], ARRAY['biceps']::text[], false, ARRAY['גב זקוף וחזה פתוח, לא מתכופפים קדימה עם המשיכה', 'מושכים את המרפקים אחורה וסוגרים שכמות', 'לא מתנדנדים עם הגוף — רק הידיים והגב עובדים', 'עצירה קצרה כשהידית קרובה לבטן, ואז חזרה איטית']::text[]),
  ('yonatan', 'upper-04', 'upper', 3, 'פרפר לחזה במכונה (Chest Fly Machine)', 3, '12', true, 2.5, 'machine', 'front', ARRAY['chest']::text[], '{}'::text[], false, ARRAY['כוונון מושב כך שהידיות בגובה הכתפיים', 'מקרבים ידיים בקשת רחבה, מרפקים בכיפוף קל וקבוע', 'לא זורקים את המשקל בחזרה החוצה', 'בפתיחה מרגישים מתיחה נעימה בחזה — לא כאב בכתף']::text[]),
  ('yonatan', 'upper-05', 'upper', 4, 'לחיצת כתפיים בישיבה (Shoulder Press)', 3, '10', true, 2, 'dumbbell', 'front', ARRAY['shoulders']::text[], ARRAY['triceps']::text[], false, ARRAY['גב תחתון צמוד למשענת, בטן מכווצת קלות', 'דוחפים למעלה בלי לקשת יתר בגב התחתון', 'לא נועלים מרפקים בחוזקה בקצה העלייה', 'מורידים עד שהמרפקים בערך בגובה הכתפיים']::text[]),
  ('yonatan', 'upper-06', 'upper', 5, 'כפיפת מרפקים במוט בישיבה (Seated Barbell Curl)', 3, '10', true, 2.5, 'barbell', 'front', ARRAY['biceps']::text[], ARRAY['forearms']::text[], false, ARRAY['ישיבה זקופה על ספסל, גב תחתון ניטרלי', 'הישיבה מנטרלת תנופה — אם הגוף זז, המשקל כבד מדי', 'מרפקים לא זזים קדימה בזמן העלייה', 'ירידה איטית עד יישור כמעט מלא']::text[]),
  ('yonatan', 'upper-07', 'upper', 6, 'טרייספס בפולי (Cable Triceps Pushdown)', 3, '12', true, 2.5, 'cable', 'back', ARRAY['triceps']::text[], '{}'::text[], false, ARRAY['מרפקים צמודים לגוף וקבועים במקום', 'רק האמה זזה — הכתף לא יורדת ולא עולה', 'פושטים עד הסוף בלי לנעול בחוזקה', 'חוזרים באיטיות למעלה, בלי לתת למשקל למשוך']::text[]),
  ('yonatan', 'upper-p1', 'upper', 7, 'חתירה במכונה (Machine Row)', 3, '10', true, 2.5, 'machine', 'back', ARRAY['lats', 'traps']::text[], ARRAY['biceps']::text[], true, ARRAY['חזה צמוד לכרית התמיכה לאורך כל התנועה', 'מושכים מרפקים אחורה, שכמות מתקרבות זו לזו', 'לא מרימים כתפיים לכיוון האוזניים', 'חזרה איטית קדימה, בלי לשחרר את המשקל בבת אחת']::text[]),
  ('yonatan', 'upper-p2', 'upper', 8, 'כפיפת מרפקים במוט בעמידה (Barbell Curl)', 3, '10', true, 2.5, 'barbell', 'front', ARRAY['biceps']::text[], ARRAY['forearms']::text[], true, ARRAY['אחיזה ברוחב כתפיים בערך, כפות ידיים למעלה', 'מרפקים צמודים לצדי הגוף וקבועים במקום', 'עולים בשליטה — בלי תנופת גב או ברכיים', 'ירידה איטית עד יישור כמעט מלא, כאן קורה רוב הבנייה']::text[]),
  ('yonatan', 'upper-p3', 'upper', 9, 'הרמות צד לכתפיים (Lateral Raise)', 3, '12', true, 1, 'dumbbell', 'front', ARRAY['shoulders']::text[], '{}'::text[], true, ARRAY['מרפקים בכיפוף קל קבוע לאורך התנועה', 'מרימים עד גובה הכתפיים בערך — לא יותר', 'תנועה איטית, בלי תנופה מהגוף', 'ירידה מבוקרת, המשקל לא נופל למטה']::text[]),
  ('yonatan', 'upper-p4', 'upper', 10, 'כפיפת מרפק פטיש (Hammer Curl)', 3, '10', true, 2, 'dumbbell', 'front', ARRAY['biceps', 'forearms']::text[], '{}'::text[], true, ARRAY['אחיזה ניטרלית — האגודלים כלפי מעלה כל הזמן', 'מרפקים צמודים לגוף וקבועים', 'עלייה בשליטה, ירידה איטית עוד יותר', 'לא מנענעים את הגוף כדי לעזור']::text[]),
  ('yonatan', 'upper-p5', 'upper', 11, 'טרייספס מעל הראש בכבל (Overhead Extension)', 3, '12', true, 2.5, 'cable', 'back', ARRAY['triceps']::text[], '{}'::text[], true, ARRAY['מרפקים קרובים לראש וקבועים במקום', 'מיישרים כמעט עד הסוף מעל הראש', 'לא מרחיקים את המרפקים הצידה', 'תנועה מבוקרת בשני הכיוונים, בלי קשת בגב']::text[]),
  ('yonatan', 'upper-p6', 'upper', 12, 'לחיצת חזה בשיפוע עם משקולות (Incline DB Press)', 3, '10', true, 2, 'dumbbell', 'front', ARRAY['chest']::text[], ARRAY['shoulders', 'triceps']::text[], true, ARRAY['ספסל בשיפוע 30 מעלות בערך, לא תלול יותר', 'מרפקים בזווית 45 מעלות מהגוף, לא פתוחים לגמרי', 'דוחפים למעלה ומעט פנימה, המשקולות מתקרבות', 'ירידה מבוקרת עד מתיחה נעימה בחזה']::text[]),
  ('yonatan', 'upper-p7', 'upper', 13, 'Face Pull בכבל', 3, '15', true, 2.5, 'cable', 'back', ARRAY['traps', 'shoulders']::text[], '{}'::text[], true, ARRAY['מושכים את החבל לגובה הפנים, מרפקים גבוהים', 'פותחים את הידיים החוצה בסוף המשיכה', 'משקל קל — זה תרגיל יציבה, לא תרגיל כוח', 'חזרה איטית עם שליטה מלאה']::text[]),
  ('yonatan', 'upper-p8', 'upper', 14, 'חתירה עם משקולת יד אחת (One-Arm DB Row)', 3, '10', true, 2, 'dumbbell', 'back', ARRAY['lats']::text[], ARRAY['biceps', 'traps']::text[], true, ARRAY['יד וברך על ספסל, גב ישר ומקביל לרצפה', 'מושכים את המשקולת לכיוון האגן, לא לכיוון הכתף', 'המרפק נשאר קרוב לגוף', 'לא מסובבים את הגו כדי להרים גבוה יותר']::text[]),
  ('yonatan', 'upper-p9', 'upper', 15, 'מקבילים על ספסל (Bench Dips)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['triceps']::text[], ARRAY['chest']::text[], true, ARRAY['ידיים על ספסל יציב מאחורי הגוף, אצבעות קדימה', 'יורדים עד שהמרפק בערך ב־90 מעלות', 'הכתפיים לא נדחפות לכיוון האוזניים', 'אם קשה — מקרבים את הרגליים לגוף']::text[]),
  ('yonatan', 'upper-p10', 'upper', 16, 'מתח בעזרה (Assisted Pull-up)', 3, '8', false, 0, 'bodyweight', 'back', ARRAY['lats']::text[], ARRAY['biceps']::text[], true, ARRAY['אחיזה ברוחב כתפיים ומעט יותר', 'מתחילים מכתפיים ''נעולות'' למטה, לא רפויות', 'מושכים עד שהסנטר עובר את המוט', 'אפשר להיעזר בגומייה או במכונת עזר']::text[]),
  ('yonatan', 'lower-01', 'lower', 0, 'לחיצת רגליים (Leg Press)', 3, '10', true, 5, 'machine', 'front', ARRAY['quads']::text[], ARRAY['glutes', 'hamstrings']::text[], false, ARRAY['כפות הרגליים ברוחב כתפיים באמצע המשטח', 'לא נועלים ברכיים בחוזקה בקצה העלייה', 'לא מרימים את הישבן מהמושב בירידה', 'יורדים עד כמה שהגב התחתון נשאר צמוד']::text[]),
  ('yonatan', 'lower-02', 'lower', 1, 'יישור רגליים במכונה (Leg Extension Machine)', 3, '12', true, 2.5, 'machine', 'front', ARRAY['quads']::text[], '{}'::text[], false, ARRAY['גב צמוד למשענת, אוחזים בידיות', 'תנועה חלקה עד כמעט יישור מלא', 'עצירה קלה למעלה — לא בעיטה מהירה', 'החזרה למטה איטית יותר מהעלייה']::text[]),
  ('yonatan', 'lower-03', 'lower', 2, 'כיפוף רגליים במכונה (Leg Curl)', 3, '12', true, 2.5, 'machine', 'back', ARRAY['hamstrings']::text[], ARRAY['calves']::text[], false, ARRAY['האגן צמוד למשטח לאורך כל התנועה', 'כיפוף עד הסוף בלי לנתק את הירכיים', 'חזרה איטית ומבוקרת למטה', 'לא מסיימים בתנופה בתחתית התנועה']::text[]),
  ('yonatan', 'lower-04', 'lower', 3, 'דדליפט רומני עם משקולות (RDL)', 3, '10', true, 2.5, 'dumbbell', 'back', ARRAY['hamstrings', 'glutes']::text[], ARRAY['lowerBack']::text[], false, ARRAY['ברכיים כמעט ישרות, כיפוף קל בלבד', 'שולחים את האגן אחורה — הגב נשאר ישר', 'המשקולות נשארות צמודות לרגליים לאורך הירידה', 'עוצרים כשמרגישים מתיחה בירך האחורית, לא נמוך יותר']::text[]),
  ('yonatan', 'lower-05', 'lower', 4, 'היפ תראסט (Hip Thrust)', 3, '12', true, 5, 'dumbbell', 'back', ARRAY['glutes']::text[], ARRAY['hamstrings']::text[], false, ARRAY['כתפיים עליונות נשענות על ספסל יציב', 'דוחפים דרך העקבים, לא דרך הבהונות', 'למעלה — גוף בקו ישר מהברכיים לכתפיים', 'כיווץ חזק של הישבן בסוף, בלי לקשת בגב']::text[]),
  ('yonatan', 'lower-06', 'lower', 5, 'הרמות עקבים בעמידה (Calf Raise)', 3, '15', true, 5, 'machine', 'back', ARRAY['calves']::text[], '{}'::text[], false, ARRAY['עולים על קצות האצבעות בשליטה, לא בקפיצה', 'עצירה של שנייה למעלה — כאן השוק עובד', 'יורדים עד מתיחה קלה בשוק', 'נשענים על משטח יציב לשמירת איזון']::text[]),
  ('yonatan', 'lower-p1', 'lower', 6, 'סקוואט עם משקולת (Goblet Squat)', 3, '10', true, 2.5, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['glutes', 'abs']::text[], true, ARRAY['מחזיקים משקולת אחת צמוד לחזה', 'רגליים ברוחב כתפיים, בהונות מעט כלפי חוץ', 'יורדים עד שהירכיים בערך מקבילות לרצפה', 'ברכיים בקו עם הבהונות, גב ישר לאורך התנועה']::text[]),
  ('yonatan', 'lower-p2', 'lower', 7, 'לאנג׳ הליכה (Walking Lunge)', 3, '10 לרגל', true, 2, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], true, ARRAY['צעד גדול מספיק כדי לשמור על יציבות', 'ברך קדמית לא נופלת פנימה', 'ברך אחורית יורדת בשליטה, כמעט נוגעת ברצפה', 'גו זקוף לאורך כל התנועה']::text[]),
  ('yonatan', 'lower-p3', 'lower', 8, 'סקוואט בולגרי (Bulgarian Split Squat)', 3, '8 לרגל', true, 2, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], true, ARRAY['רגל אחורית על ספסל, רגל קדמית צעד גדול קדימה', 'יורדים ישר למטה, לא קדימה', 'רוב המשקל על העקב של הרגל הקדמית', 'מתחילים בלי משקל עד שהאיזון יציב']::text[]),
  ('yonatan', 'lower-p4', 'lower', 9, 'הרמות עקבים בישיבה (Seated Calf Raise)', 3, '15', true, 2.5, 'machine', 'back', ARRAY['calves']::text[], '{}'::text[], true, ARRAY['עולים על קצות האצבעות בשליטה, לא בקפיצה', 'עצירה של שנייה למעלה — כאן השוק עובד', 'יורדים עד מתיחה קלה בשוק', 'נשענים על משטח יציב לשמירת איזון']::text[]),
  ('yonatan', 'lower-p5', 'lower', 10, 'פתיחת ירכיים במכונה (Hip Abduction)', 3, '15', true, 2.5, 'machine', 'back', ARRAY['glutes']::text[], '{}'::text[], true, ARRAY['ישיבה זקופה, גב צמוד למשענת', 'פותחים את הברכיים החוצה בשליטה', 'עצירה קצרה בסוף הפתיחה', 'סגירה איטית — לא נותנים למשקל לחזור לבד']::text[]),
  ('yonatan', 'lower-p6', 'lower', 11, 'יישור גב (Back Extension)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['lowerBack']::text[], ARRAY['glutes', 'hamstrings']::text[], true, ARRAY['הירכיים נשענות על הכרית, הגב מתחיל ישר', 'יורדים עד מתיחה בירך האחורית', 'עולים עד קו ישר בלבד — לא מעבר לזה', 'המבט קדימה־למטה, לא כלפי מעלה']::text[]),
  ('yonatan', 'lower-p7', 'lower', 12, 'עלייה על מדרגה (Step-up)', 3, '10 לרגל', true, 2, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], true, ARRAY['מדרגה או ספסל בגובה ברך בערך', 'דוחפים דרך העקב של הרגל שעל המדרגה', 'לא נעזרים בקפיצה מהרגל התחתונה', 'ירידה איטית ומבוקרת']::text[]),
  ('yonatan', 'lower-p8', 'lower', 13, 'גשר ישבן על רגל אחת', 3, '12 לרגל', false, 0, 'bodyweight', 'back', ARRAY['glutes']::text[], ARRAY['hamstrings']::text[], true, ARRAY['רגל אחת באוויר, השנייה עם כף רגל על הרצפה', 'מרימים את האגן דרך העקב של הרגל התומכת', 'האגן נשאר ישר — לא נופל לצד', 'עצירה למעלה ואז ירידה איטית']::text[]),
  ('yonatan', 'core-01', 'core', 0, 'פלאנק (Plank)', 3, '40 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['obliques', 'lowerBack']::text[], false, ARRAY['קו ישר מהראש עד העקבים', 'בטן וישבן מכווצים, אין שקיעה באגן', 'המרפקים בדיוק מתחת לכתפיים', 'נושמים באופן קבוע — לא עוצרים נשימה']::text[]),
  ('yonatan', 'core-02', 'core', 1, 'Dead Bug', 3, '10 לצד', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], '{}'::text[], false, ARRAY['גב תחתון צמוד לרצפה לאורך כל התרגיל', 'פושטים יד ורגל נגדיות באיטיות', 'נושמים כרגיל, לא עוצרים נשימה', 'אם הגב מתרומם — מקטינים את הטווח']::text[]),
  ('yonatan', 'core-03', 'core', 2, 'הרמות רגליים בשכיבה (Leg Raise)', 3, '12', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['quads']::text[], false, ARRAY['גב תחתון צמוד לרצפה, ידיים מתחת לישבן', 'מרימים רגליים ישרות עד 90 מעלות', 'מורידים לאט בלי לגעת ברצפה', 'אם הגב מתרומם — מכופפים מעט ברכיים']::text[]),
  ('yonatan', 'core-04', 'core', 3, 'בטן אלכסונית (Russian Twist)', 3, '15 לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], false, ARRAY['גב ישר בהטיה, לא מתעגל', 'התנועה מגיעה מהליבה, לא מהידיים', 'אפשר להשאיר כפות רגליים על הרצפה בהתחלה', 'נושמים באופן קבוע לאורך התרגיל']::text[]),
  ('yonatan', 'core-05', 'core', 4, 'פלאנק צידי (Side Plank)', 3, '25 שנ׳ לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], false, ARRAY['קו ישר מהראש ועד כפות הרגליים בצד', 'האגן לא שוקע ולא מתרומם יותר מדי', 'המרפק בדיוק מתחת לכתף', 'מתחלפים צד אחרי המנוחה']::text[]),
  ('yonatan', 'core-p1', 'core', 5, 'בטן בכבל בכריעה (Cable Crunch)', 3, '15', true, 2.5, 'cable', 'front', ARRAY['abs']::text[], '{}'::text[], true, ARRAY['כורעים מול הכבל, ידיים ליד הראש', 'מכופפים מהבטן — לא מהידיים ולא מהגב התחתון', 'האגן נשאר יציב במקום', 'חזרה מבוקרת למעלה בלי לאבד מתח בבטן']::text[]),
  ('yonatan', 'core-p2', 'core', 6, 'הרמות ברכיים בתלייה (Hanging Knee Raise)', 3, '12', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['forearms']::text[], true, ARRAY['תלייה במוט, כתפיים פעילות ולא רפויות', 'מרימים ברכיים לכיוון החזה בשליטה', 'בלי נדנוד של הגוף בין החזרות', 'מורידים לאט — כאן הבטן עובדת הכי הרבה']::text[]),
  ('yonatan', 'core-p3', 'core', 7, 'אופניים (Bicycle Crunch)', 3, '15 לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], true, ARRAY['מרפק נוגע בברך הנגדית בסיבוב מהליבה', 'הגב התחתון נשאר צמוד לרצפה', 'תנועה איטית — לא מרוץ', 'לא מושכים את הצוואר עם הידיים']::text[]),
  ('yonatan', 'core-p4', 'core', 8, 'Hollow Hold', 3, '25 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], '{}'::text[], true, ARRAY['גב תחתון לחוץ לרצפה לאורך כל האחיזה', 'ידיים ורגליים ישרות ומורמות מעט', 'ככל שהידיים והרגליים קרובות לגוף — קל יותר', 'נושמים קצר ורציף, לא עוצרים נשימה']::text[]),
  ('yonatan', 'core-p5', 'core', 9, 'Bird Dog', 3, '10 לצד', false, 0, 'bodyweight', 'back', ARRAY['lowerBack']::text[], ARRAY['abs', 'glutes']::text[], true, ARRAY['ארבע נקודות, גב ישר ומקביל לרצפה', 'פושטים יד ורגל נגדיות עד קו ישר', 'האגן לא מסתובב הצידה', 'עצירה של שנייה־שתיים בכל חזרה']::text[]),
  ('yonatan', 'core-p6', 'core', 10, 'מטפסי הרים (Mountain Climbers)', 3, '30 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['quads']::text[], true, ARRAY['תנוחת שכיבת סמיכה, ידיים מתחת לכתפיים', 'מביאים ברך לכיוון החזה לסירוגין', 'האגן לא עולה ולא שוקע', 'קצב קבוע ונשימה רציפה']::text[]),
  ('yonatan', 'core-p7', 'core', 11, 'סופרמן (Superman)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['lowerBack']::text[], ARRAY['glutes']::text[], true, ARRAY['שוכבים על הבטן, ידיים ורגליים ישרות', 'מרימים בו־זמנית ידיים, חזה ורגליים', 'עוצרים רגע למעלה — כיווץ בגב התחתון ובישבן', 'ירידה מבוקרת, לא נופלים בבת אחת']::text[]),
  ('yonatan', 'home-01', 'home', 0, 'סקוואט משקל גוף (Bodyweight Squat)', 3, '15', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], false, ARRAY['רגליים ברוחב כתפיים, בהונות מעט כלפי חוץ', 'יורדים כאילו יושבים על כיסא', 'גב ישר, מבט קדימה', 'דוחפים דרך העקבים לחזרה למעלה']::text[]),
  ('yonatan', 'home-02', 'home', 1, 'שכיבות סמיכה (Push-ups)', 3, '12', false, 0, 'bodyweight', 'front', ARRAY['chest']::text[], ARRAY['triceps', 'shoulders']::text[], false, ARRAY['ידיים קצת רחבות מהכתפיים', 'גוף בקו ישר מהראש עד העקבים', 'יורדים עד שהחזה כמעט נוגע ברצפה', 'אם קשה — אפשר לרדת על הברכיים']::text[]),
  ('yonatan', 'home-03', 'home', 2, 'גשר ישבן (Glute Bridge)', 3, '15', false, 0, 'bodyweight', 'back', ARRAY['glutes']::text[], ARRAY['hamstrings']::text[], false, ARRAY['כפות רגליים קרובות לישבן, ברוחב כתפיים', 'דוחפים דרך העקבים ומרימים את האגן', 'כיווץ חזק של הישבן למעלה, בלי לקשת בגב', 'ירידה מבוקרת, לא נופלים']::text[]),
  ('yonatan', 'home-04', 'home', 3, 'לאנג׳ (Lunge)', 3, '10 לרגל', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], false, ARRAY['צעד גדול מספיק כדי לשמור על יציבות', 'ברך קדמית לא נופלת פנימה', 'ברך אחורית יורדת בשליטה, כמעט נוגעת ברצפה', 'גו זקוף לאורך כל התנועה']::text[]),
  ('yonatan', 'home-05', 'home', 4, 'סופרמן (Superman)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['lowerBack']::text[], ARRAY['glutes']::text[], false, ARRAY['שוכבים על הבטן, ידיים ורגליים ישרות', 'מרימים בו־זמנית ידיים, חזה ורגליים', 'עוצרים רגע למעלה — כיווץ בגב התחתון ובישבן', 'ירידה מבוקרת, לא נופלים בבת אחת']::text[]),
  ('yonatan', 'home-06', 'home', 5, 'שכיבות סמיכה צרות (Diamond Push-ups)', 3, '10', false, 0, 'bodyweight', 'back', ARRAY['triceps']::text[], ARRAY['chest']::text[], false, ARRAY['ידיים קרובות מתחת לחזה, אצבעות יוצרות משולש', 'מרפקים נשארים קרובים לגוף', 'יורדים עד שהחזה כמעט נוגע בידיים', 'אם קשה — אפשר לרדת על הברכיים']::text[]),
  ('yonatan', 'home-07', 'home', 6, 'פלאנק (Plank)', 3, '40 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['obliques', 'lowerBack']::text[], false, ARRAY['קו ישר מהראש עד העקבים', 'בטן וישבן מכווצים, אין שקיעה באגן', 'המרפקים בדיוק מתחת לכתפיים', 'נושמים באופן קבוע — לא עוצרים נשימה']::text[]),
  ('yonatan', 'home-p1', 'home', 7, 'שכיבות סמיכה פייק (Pike Push-ups)', 3, '10', false, 0, 'bodyweight', 'front', ARRAY['shoulders']::text[], ARRAY['triceps']::text[], true, ARRAY['ישבן גבוה, הגוף יוצר צורת V הפוכה', 'יורדים עם הראש לכיוון הרצפה בין הידיים', 'המרפקים נשארים קרובים, לא מתפרשים החוצה', 'ככל שהרגליים גבוהות יותר — קשה יותר']::text[]),
  ('yonatan', 'home-p2', 'home', 8, 'מקבילים על כיסא (Bench Dips)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['triceps']::text[], ARRAY['chest']::text[], true, ARRAY['ידיים על ספסל יציב מאחורי הגוף, אצבעות קדימה', 'יורדים עד שהמרפק בערך ב־90 מעלות', 'הכתפיים לא נדחפות לכיוון האוזניים', 'אם קשה — מקרבים את הרגליים לגוף']::text[]),
  ('yonatan', 'home-p3', 'home', 9, 'ישיבת קיר (Wall Sit)', 3, '45 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], true, ARRAY['גב צמוד לקיר, ברכיים בזווית 90 מעלות', 'המשקל על העקבים, לא על הבהונות', 'לא נשענים עם הידיים על הירכיים', 'נושמים רגיל — הזמן עובר לאט יותר בלי אוויר']::text[]),
  ('yonatan', 'home-p4', 'home', 10, 'גשר ישבן על רגל אחת', 3, '12 לרגל', false, 0, 'bodyweight', 'back', ARRAY['glutes']::text[], ARRAY['hamstrings']::text[], true, ARRAY['רגל אחת באוויר, השנייה עם כף רגל על הרצפה', 'מרימים את האגן דרך העקב של הרגל התומכת', 'האגן נשאר ישר — לא נופל לצד', 'עצירה למעלה ואז ירידה איטית']::text[]),
  ('yonatan', 'home-p5', 'home', 11, 'בורפי (Burpee)', 3, '10', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['chest', 'abs']::text[], true, ARRAY['מתחילים בעמידה, יורדים לשכיבת סמיכה', 'הגב לא מתעגל בזמן הירידה', 'קמים ומסיימים בקפיצה קלה', 'אפשר לוותר על הקפיצה ולעשות צעד במקום']::text[]),
  ('yonatan', 'home-p6', 'home', 12, 'קפיצות פישוק (Jumping Jacks)', 3, '40 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['calves']::text[], ARRAY['shoulders']::text[], true, ARRAY['קפיצה קלה, נחיתה רכה על כרית כף הרגל', 'ידיים עולות עד מעל הראש', 'קצב קבוע לאורך כל הסט', 'אם הברכיים רגישות — עושים גרסת צעד במקום קפיצה']::text[]),
  ('yonatan', 'home-p7', 'home', 13, 'פלאנק צידי (Side Plank)', 3, '25 שנ׳ לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], true, ARRAY['קו ישר מהראש ועד כפות הרגליים בצד', 'האגן לא שוקע ולא מתרומם יותר מדי', 'המרפק בדיוק מתחת לכתף', 'מתחלפים צד אחרי המנוחה']::text[]),
  ('yonatan', 'home-p8', 'home', 14, 'בטן אלכסונית (Russian Twist)', 3, '15 לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], true, ARRAY['גב ישר בהטיה, לא מתעגל', 'התנועה מגיעה מהליבה, לא מהידיים', 'אפשר להשאיר כפות רגליים על הרצפה בהתחלה', 'נושמים באופן קבוע לאורך התרגיל']::text[])
  on conflict (profile_id, ex_key) do update set program_id=excluded.program_id,
    sort_order=excluded.sort_order, name=excluded.name, target_sets=excluded.target_sets,
    target_reps=excluded.target_reps, weighted=excluded.weighted, increment=excluded.increment,
    equipment=excluded.equipment, body_view=excluded.body_view, muscles=excluded.muscles,
    muscles_sec=excluded.muscles_sec, in_pool=excluded.in_pool, cues=excluded.cues;
insert into cardio_state (profile_id, kind) values
  ('yonatan', 'running'),
  ('yonatan', 'cycling'),
  ('yonatan', 'football'),
  ('yonatan', 'basketball'),
  ('yonatan', 'tennis'),
  ('yonatan', 'swimming'),
  ('yonatan', 'walking'),
  ('yonatan', 'jumprope')
  on conflict do nothing;
insert into app_settings (profile_id, k, v) values
  ('yonatan', 'prefs', '{"hidden":{},"added":{},"plan":{}}'::jsonb)
  on conflict do nothing;
insert into exercise_state (profile_id, ex_key)
  select profile_id, ex_key from exercises where profile_id = 'yonatan'
  on conflict do nothing;

-- ---------- איתמר ----------
insert into profiles (id, name, accent, goal, week_goal) values
  ('itamar', 'איתמר', '#FF7EB6', 'בניית שריר וכוח', 4)
  on conflict (id) do update set name=excluded.name, accent=excluded.accent,
    goal=excluded.goal, week_goal=excluded.week_goal;
insert into programs (profile_id, id, label, sub, icon, hex, kind, sort_order) values
  ('itamar', 'upper', 'חדר כושר · עליון', 'פלג גוף עליון', '🏋️', '#FF4D6D', 'strength', 0),
  ('itamar', 'lower', 'חדר כושר · תחתון', 'פלג גוף תחתון', '🦵', '#3DA9FC', 'strength', 1),
  ('itamar', 'core', 'בטן וליבה', 'ליבה', '🔥', '#FFD23F', 'strength', 2),
  ('itamar', 'home', 'אימון ביתי', 'בלי ציוד', '🏠', '#2FE6A7', 'strength', 3),
  ('itamar', 'cardio', 'אירובי וספורט', 'זמן בלבד', '🏃', '#3DA9FC', 'cardio', 4)
  on conflict (profile_id, id) do update set label=excluded.label, sub=excluded.sub,
    icon=excluded.icon, hex=excluded.hex, kind=excluded.kind, sort_order=excluded.sort_order;
insert into exercises (profile_id, ex_key, program_id, sort_order, name, target_sets,
                       target_reps, weighted, increment, equipment, body_view,
                       muscles, muscles_sec, in_pool, cues) values
  ('itamar', 'upper-01', 'upper', 0, 'לחיצת חזה במכונה (Chest Press Machine)', 4, '8', true, 2.5, 'machine', 'front', ARRAY['chest']::text[], ARRAY['triceps', 'shoulders']::text[], false, ARRAY['מכוונים גובה מושב כך שהידיות בגובה החזה', 'דוחפים קדימה בשליטה, בלי לנעול מרפקים בסוף', 'חוזרים לאט לנקודת ההתחלה — הירידה היא חצי מהתרגיל', 'גב וכתפיים צמודים למשענת לאורך כל התנועה']::text[]),
  ('itamar', 'upper-02', 'upper', 1, 'פולי עליון (Lat Pulldown)', 4, '10', true, 2.5, 'cable', 'back', ARRAY['lats']::text[], ARRAY['biceps', 'traps']::text[], false, ARRAY['אחיזה מעט רחבה מהכתפיים, אגודל סוגר על המוט', 'מושכים את המרפקים למטה ואחורה, החזה מוביל כלפי מעלה', 'לא מתנופפים אחורה עם הגוף כדי לעזור למשקל', 'עוצרים רגע כשהמוט בגובה הסנטר, וחוזרים בשליטה מלאה']::text[]),
  ('itamar', 'upper-03', 'upper', 2, 'חתירה במכונה (Machine Row)', 3, '10', true, 2.5, 'machine', 'back', ARRAY['lats', 'traps']::text[], ARRAY['biceps']::text[], false, ARRAY['חזה צמוד לכרית התמיכה לאורך כל התנועה', 'מושכים מרפקים אחורה, שכמות מתקרבות זו לזו', 'לא מרימים כתפיים לכיוון האוזניים', 'חזרה איטית קדימה, בלי לשחרר את המשקל בבת אחת']::text[]),
  ('itamar', 'upper-04', 'upper', 3, 'חתירה בפולי בישיבה (Seated Cable Row)', 3, '10', true, 2.5, 'cable', 'back', ARRAY['lats', 'traps']::text[], ARRAY['biceps']::text[], false, ARRAY['גב זקוף וחזה פתוח, לא מתכופפים קדימה עם המשיכה', 'מושכים את המרפקים אחורה וסוגרים שכמות', 'לא מתנדנדים עם הגוף — רק הידיים והגב עובדים', 'עצירה קצרה כשהידית קרובה לבטן, ואז חזרה איטית']::text[]),
  ('itamar', 'upper-05', 'upper', 4, 'פרפר לחזה במכונה (Chest Fly Machine)', 3, '12', true, 2.5, 'machine', 'front', ARRAY['chest']::text[], '{}'::text[], false, ARRAY['כוונון מושב כך שהידיות בגובה הכתפיים', 'מקרבים ידיים בקשת רחבה, מרפקים בכיפוף קל וקבוע', 'לא זורקים את המשקל בחזרה החוצה', 'בפתיחה מרגישים מתיחה נעימה בחזה — לא כאב בכתף']::text[]),
  ('itamar', 'upper-06', 'upper', 5, 'לחיצת כתפיים בישיבה (Shoulder Press)', 3, '10', true, 2, 'dumbbell', 'front', ARRAY['shoulders']::text[], ARRAY['triceps']::text[], false, ARRAY['גב תחתון צמוד למשענת, בטן מכווצת קלות', 'דוחפים למעלה בלי לקשת יתר בגב התחתון', 'לא נועלים מרפקים בחוזקה בקצה העלייה', 'מורידים עד שהמרפקים בערך בגובה הכתפיים']::text[]),
  ('itamar', 'upper-07', 'upper', 6, 'כפיפת מרפקים עם שתי משקולות בעמידה (Standing DB Curl)', 3, '10', true, 2, 'dumbbell', 'front', ARRAY['biceps']::text[], ARRAY['forearms']::text[], false, ARRAY['עמידה זקופה, שתי משקולות, רגליים ברוחב אגן', 'מרפקים צמודים לגוף — רק האמה זזה', 'אפשר שתי ידיים יחד או לסירוגין', 'בלי נדנוד של הגו — הגב לא אמור להשתתף']::text[]),
  ('itamar', 'upper-08', 'upper', 7, 'טרייספס בפולי (Cable Triceps Pushdown)', 3, '12', true, 2.5, 'cable', 'back', ARRAY['triceps']::text[], '{}'::text[], false, ARRAY['מרפקים צמודים לגוף וקבועים במקום', 'רק האמה זזה — הכתף לא יורדת ולא עולה', 'פושטים עד הסוף בלי לנעול בחוזקה', 'חוזרים באיטיות למעלה, בלי לתת למשקל למשוך']::text[]),
  ('itamar', 'upper-p3', 'upper', 8, 'הרמות צד לכתפיים (Lateral Raise)', 3, '12', true, 1, 'dumbbell', 'front', ARRAY['shoulders']::text[], '{}'::text[], true, ARRAY['מרפקים בכיפוף קל קבוע לאורך התנועה', 'מרימים עד גובה הכתפיים בערך — לא יותר', 'תנועה איטית, בלי תנופה מהגוף', 'ירידה מבוקרת, המשקל לא נופל למטה']::text[]),
  ('itamar', 'upper-p4', 'upper', 9, 'כפיפת מרפק פטיש בעמידה (Hammer Curl)', 3, '10', true, 2, 'dumbbell', 'front', ARRAY['biceps', 'forearms']::text[], '{}'::text[], true, ARRAY['אחיזה ניטרלית — האגודלים כלפי מעלה כל הזמן', 'מרפקים צמודים לגוף וקבועים', 'עלייה בשליטה, ירידה איטית עוד יותר', 'לא מנענעים את הגוף כדי לעזור']::text[]),
  ('itamar', 'upper-p5', 'upper', 10, 'טרייספס מעל הראש בכבל (Overhead Extension)', 3, '12', true, 2.5, 'cable', 'back', ARRAY['triceps']::text[], '{}'::text[], true, ARRAY['מרפקים קרובים לראש וקבועים במקום', 'מיישרים כמעט עד הסוף מעל הראש', 'לא מרחיקים את המרפקים הצידה', 'תנועה מבוקרת בשני הכיוונים, בלי קשת בגב']::text[]),
  ('itamar', 'upper-p6', 'upper', 11, 'לחיצת חזה בשיפוע עם משקולות (Incline DB Press)', 3, '10', true, 2, 'dumbbell', 'front', ARRAY['chest']::text[], ARRAY['shoulders', 'triceps']::text[], true, ARRAY['ספסל בשיפוע 30 מעלות בערך, לא תלול יותר', 'מרפקים בזווית 45 מעלות מהגוף, לא פתוחים לגמרי', 'דוחפים למעלה ומעט פנימה, המשקולות מתקרבות', 'ירידה מבוקרת עד מתיחה נעימה בחזה']::text[]),
  ('itamar', 'upper-p7', 'upper', 12, 'Face Pull בכבל', 3, '15', true, 2.5, 'cable', 'back', ARRAY['traps', 'shoulders']::text[], '{}'::text[], true, ARRAY['מושכים את החבל לגובה הפנים, מרפקים גבוהים', 'פותחים את הידיים החוצה בסוף המשיכה', 'משקל קל — זה תרגיל יציבה, לא תרגיל כוח', 'חזרה איטית עם שליטה מלאה']::text[]),
  ('itamar', 'upper-p8', 'upper', 13, 'חתירה עם משקולת יד אחת (One-Arm DB Row)', 3, '10', true, 2, 'dumbbell', 'back', ARRAY['lats']::text[], ARRAY['biceps', 'traps']::text[], true, ARRAY['יד וברך על ספסל, גב ישר ומקביל לרצפה', 'מושכים את המשקולת לכיוון האגן, לא לכיוון הכתף', 'המרפק נשאר קרוב לגוף', 'לא מסובבים את הגו כדי להרים גבוה יותר']::text[]),
  ('itamar', 'upper-p9', 'upper', 14, 'מקבילים על ספסל (Bench Dips)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['triceps']::text[], ARRAY['chest']::text[], true, ARRAY['ידיים על ספסל יציב מאחורי הגוף, אצבעות קדימה', 'יורדים עד שהמרפק בערך ב־90 מעלות', 'הכתפיים לא נדחפות לכיוון האוזניים', 'אם קשה — מקרבים את הרגליים לגוף']::text[]),
  ('itamar', 'upper-p10', 'upper', 15, 'מתח בעזרה (Assisted Pull-up)', 3, '8', false, 0, 'bodyweight', 'back', ARRAY['lats']::text[], ARRAY['biceps']::text[], true, ARRAY['אחיזה ברוחב כתפיים ומעט יותר', 'מתחילים מכתפיים ''נעולות'' למטה, לא רפויות', 'מושכים עד שהסנטר עובר את המוט', 'אפשר להיעזר בגומייה או במכונת עזר']::text[]),
  ('itamar', 'upper-p11', 'upper', 16, 'כפיפת מרפקים בכבל בעמידה (Cable Curl)', 3, '12', true, 2.5, 'cable', 'front', ARRAY['biceps']::text[], ARRAY['forearms']::text[], true, ARRAY['עמידה זקופה, שתי משקולות, רגליים ברוחב אגן', 'מרפקים צמודים לגוף — רק האמה זזה', 'אפשר שתי ידיים יחד או לסירוגין', 'בלי נדנוד של הגו — הגב לא אמור להשתתף']::text[]),
  ('itamar', 'lower-01', 'lower', 0, 'לחיצת רגליים (Leg Press)', 4, '10', true, 5, 'machine', 'front', ARRAY['quads']::text[], ARRAY['glutes', 'hamstrings']::text[], false, ARRAY['כפות הרגליים ברוחב כתפיים באמצע המשטח', 'לא נועלים ברכיים בחוזקה בקצה העלייה', 'לא מרימים את הישבן מהמושב בירידה', 'יורדים עד כמה שהגב התחתון נשאר צמוד']::text[]),
  ('itamar', 'lower-02', 'lower', 1, 'יישור רגליים במכונה (Leg Extension Machine)', 3, '12', true, 2.5, 'machine', 'front', ARRAY['quads']::text[], '{}'::text[], false, ARRAY['גב צמוד למשענת, אוחזים בידיות', 'תנועה חלקה עד כמעט יישור מלא', 'עצירה קלה למעלה — לא בעיטה מהירה', 'החזרה למטה איטית יותר מהעלייה']::text[]),
  ('itamar', 'lower-03', 'lower', 2, 'כיפוף רגליים במכונה (Leg Curl)', 3, '12', true, 2.5, 'machine', 'back', ARRAY['hamstrings']::text[], ARRAY['calves']::text[], false, ARRAY['האגן צמוד למשטח לאורך כל התנועה', 'כיפוף עד הסוף בלי לנתק את הירכיים', 'חזרה איטית ומבוקרת למטה', 'לא מסיימים בתנופה בתחתית התנועה']::text[]),
  ('itamar', 'lower-04', 'lower', 3, 'דדליפט רומני עם משקולות (RDL)', 3, '8', true, 2.5, 'dumbbell', 'back', ARRAY['hamstrings', 'glutes']::text[], ARRAY['lowerBack']::text[], false, ARRAY['ברכיים כמעט ישרות, כיפוף קל בלבד', 'שולחים את האגן אחורה — הגב נשאר ישר', 'המשקולות נשארות צמודות לרגליים לאורך הירידה', 'עוצרים כשמרגישים מתיחה בירך האחורית, לא נמוך יותר']::text[]),
  ('itamar', 'lower-05', 'lower', 4, 'סקוואט עם משקולת (Goblet Squat)', 3, '10', true, 2.5, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['glutes', 'abs']::text[], false, ARRAY['מחזיקים משקולת אחת צמוד לחזה', 'רגליים ברוחב כתפיים, בהונות מעט כלפי חוץ', 'יורדים עד שהירכיים בערך מקבילות לרצפה', 'ברכיים בקו עם הבהונות, גב ישר לאורך התנועה']::text[]),
  ('itamar', 'lower-06', 'lower', 5, 'הרמות עקבים בעמידה (Calf Raise)', 4, '15', true, 5, 'machine', 'back', ARRAY['calves']::text[], '{}'::text[], false, ARRAY['עולים על קצות האצבעות בשליטה, לא בקפיצה', 'עצירה של שנייה למעלה — כאן השוק עובד', 'יורדים עד מתיחה קלה בשוק', 'נשענים על משטח יציב לשמירת איזון']::text[]),
  ('itamar', 'lower-p1', 'lower', 6, 'סקוואט עם משקולת (Goblet Squat)', 3, '10', true, 2.5, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['glutes', 'abs']::text[], true, ARRAY['מחזיקים משקולת אחת צמוד לחזה', 'רגליים ברוחב כתפיים, בהונות מעט כלפי חוץ', 'יורדים עד שהירכיים בערך מקבילות לרצפה', 'ברכיים בקו עם הבהונות, גב ישר לאורך התנועה']::text[]),
  ('itamar', 'lower-p2', 'lower', 7, 'לאנג׳ הליכה (Walking Lunge)', 3, '10 לרגל', true, 2, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], true, ARRAY['צעד גדול מספיק כדי לשמור על יציבות', 'ברך קדמית לא נופלת פנימה', 'ברך אחורית יורדת בשליטה, כמעט נוגעת ברצפה', 'גו זקוף לאורך כל התנועה']::text[]),
  ('itamar', 'lower-p3', 'lower', 8, 'סקוואט בולגרי (Bulgarian Split Squat)', 3, '8 לרגל', true, 2, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], true, ARRAY['רגל אחורית על ספסל, רגל קדמית צעד גדול קדימה', 'יורדים ישר למטה, לא קדימה', 'רוב המשקל על העקב של הרגל הקדמית', 'מתחילים בלי משקל עד שהאיזון יציב']::text[]),
  ('itamar', 'lower-p4', 'lower', 9, 'הרמות עקבים בישיבה (Seated Calf Raise)', 3, '15', true, 2.5, 'machine', 'back', ARRAY['calves']::text[], '{}'::text[], true, ARRAY['עולים על קצות האצבעות בשליטה, לא בקפיצה', 'עצירה של שנייה למעלה — כאן השוק עובד', 'יורדים עד מתיחה קלה בשוק', 'נשענים על משטח יציב לשמירת איזון']::text[]),
  ('itamar', 'lower-p5', 'lower', 10, 'פתיחת ירכיים במכונה (Hip Abduction)', 3, '15', true, 2.5, 'machine', 'back', ARRAY['glutes']::text[], '{}'::text[], true, ARRAY['ישיבה זקופה, גב צמוד למשענת', 'פותחים את הברכיים החוצה בשליטה', 'עצירה קצרה בסוף הפתיחה', 'סגירה איטית — לא נותנים למשקל לחזור לבד']::text[]),
  ('itamar', 'lower-p6', 'lower', 11, 'יישור גב (Back Extension)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['lowerBack']::text[], ARRAY['glutes', 'hamstrings']::text[], true, ARRAY['הירכיים נשענות על הכרית, הגב מתחיל ישר', 'יורדים עד מתיחה בירך האחורית', 'עולים עד קו ישר בלבד — לא מעבר לזה', 'המבט קדימה־למטה, לא כלפי מעלה']::text[]),
  ('itamar', 'lower-p7', 'lower', 12, 'עלייה על מדרגה (Step-up)', 3, '10 לרגל', true, 2, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], true, ARRAY['מדרגה או ספסל בגובה ברך בערך', 'דוחפים דרך העקב של הרגל שעל המדרגה', 'לא נעזרים בקפיצה מהרגל התחתונה', 'ירידה איטית ומבוקרת']::text[]),
  ('itamar', 'lower-p8', 'lower', 13, 'גשר ישבן על רגל אחת', 3, '12 לרגל', false, 0, 'bodyweight', 'back', ARRAY['glutes']::text[], ARRAY['hamstrings']::text[], true, ARRAY['רגל אחת באוויר, השנייה עם כף רגל על הרצפה', 'מרימים את האגן דרך העקב של הרגל התומכת', 'האגן נשאר ישר — לא נופל לצד', 'עצירה למעלה ואז ירידה איטית']::text[]),
  ('itamar', 'core-01', 'core', 0, 'בטן בכבל בכריעה (Cable Crunch)', 3, '15', true, 2.5, 'cable', 'front', ARRAY['abs']::text[], '{}'::text[], false, ARRAY['כורעים מול הכבל, ידיים ליד הראש', 'מכופפים מהבטן — לא מהידיים ולא מהגב התחתון', 'האגן נשאר יציב במקום', 'חזרה מבוקרת למעלה בלי לאבד מתח בבטן']::text[]),
  ('itamar', 'core-02', 'core', 1, 'הרמות ברכיים בתלייה (Hanging Knee Raise)', 3, '12', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['forearms']::text[], false, ARRAY['תלייה במוט, כתפיים פעילות ולא רפויות', 'מרימים ברכיים לכיוון החזה בשליטה', 'בלי נדנוד של הגוף בין החזרות', 'מורידים לאט — כאן הבטן עובדת הכי הרבה']::text[]),
  ('itamar', 'core-03', 'core', 2, 'פלאנק (Plank)', 3, '45 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['obliques', 'lowerBack']::text[], false, ARRAY['קו ישר מהראש עד העקבים', 'בטן וישבן מכווצים, אין שקיעה באגן', 'המרפקים בדיוק מתחת לכתפיים', 'נושמים באופן קבוע — לא עוצרים נשימה']::text[]),
  ('itamar', 'core-04', 'core', 3, 'בטן אלכסונית (Russian Twist)', 3, '15 לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], false, ARRAY['גב ישר בהטיה, לא מתעגל', 'התנועה מגיעה מהליבה, לא מהידיים', 'אפשר להשאיר כפות רגליים על הרצפה בהתחלה', 'נושמים באופן קבוע לאורך התרגיל']::text[]),
  ('itamar', 'core-05', 'core', 4, 'פלאנק צידי (Side Plank)', 3, '30 שנ׳ לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], false, ARRAY['קו ישר מהראש ועד כפות הרגליים בצד', 'האגן לא שוקע ולא מתרומם יותר מדי', 'המרפק בדיוק מתחת לכתף', 'מתחלפים צד אחרי המנוחה']::text[]),
  ('itamar', 'core-p2', 'core', 5, 'הרמות ברכיים בתלייה (Hanging Knee Raise)', 3, '12', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['forearms']::text[], true, ARRAY['תלייה במוט, כתפיים פעילות ולא רפויות', 'מרימים ברכיים לכיוון החזה בשליטה', 'בלי נדנוד של הגוף בין החזרות', 'מורידים לאט — כאן הבטן עובדת הכי הרבה']::text[]),
  ('itamar', 'core-p3', 'core', 6, 'אופניים (Bicycle Crunch)', 3, '15 לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], true, ARRAY['מרפק נוגע בברך הנגדית בסיבוב מהליבה', 'הגב התחתון נשאר צמוד לרצפה', 'תנועה איטית — לא מרוץ', 'לא מושכים את הצוואר עם הידיים']::text[]),
  ('itamar', 'core-p4', 'core', 7, 'Hollow Hold', 3, '25 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], '{}'::text[], true, ARRAY['גב תחתון לחוץ לרצפה לאורך כל האחיזה', 'ידיים ורגליים ישרות ומורמות מעט', 'ככל שהידיים והרגליים קרובות לגוף — קל יותר', 'נושמים קצר ורציף, לא עוצרים נשימה']::text[]),
  ('itamar', 'core-p5', 'core', 8, 'Bird Dog', 3, '10 לצד', false, 0, 'bodyweight', 'back', ARRAY['lowerBack']::text[], ARRAY['abs', 'glutes']::text[], true, ARRAY['ארבע נקודות, גב ישר ומקביל לרצפה', 'פושטים יד ורגל נגדיות עד קו ישר', 'האגן לא מסתובב הצידה', 'עצירה של שנייה־שתיים בכל חזרה']::text[]),
  ('itamar', 'core-p6', 'core', 9, 'מטפסי הרים (Mountain Climbers)', 3, '30 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['quads']::text[], true, ARRAY['תנוחת שכיבת סמיכה, ידיים מתחת לכתפיים', 'מביאים ברך לכיוון החזה לסירוגין', 'האגן לא עולה ולא שוקע', 'קצב קבוע ונשימה רציפה']::text[]),
  ('itamar', 'core-p7', 'core', 10, 'סופרמן (Superman)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['lowerBack']::text[], ARRAY['glutes']::text[], true, ARRAY['שוכבים על הבטן, ידיים ורגליים ישרות', 'מרימים בו־זמנית ידיים, חזה ורגליים', 'עוצרים רגע למעלה — כיווץ בגב התחתון ובישבן', 'ירידה מבוקרת, לא נופלים בבת אחת']::text[]),
  ('itamar', 'home-01', 'home', 0, 'סקוואט משקל גוף (Bodyweight Squat)', 3, '15', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], false, ARRAY['רגליים ברוחב כתפיים, בהונות מעט כלפי חוץ', 'יורדים כאילו יושבים על כיסא', 'גב ישר, מבט קדימה', 'דוחפים דרך העקבים לחזרה למעלה']::text[]),
  ('itamar', 'home-02', 'home', 1, 'שכיבות סמיכה (Push-ups)', 3, '12', false, 0, 'bodyweight', 'front', ARRAY['chest']::text[], ARRAY['triceps', 'shoulders']::text[], false, ARRAY['ידיים קצת רחבות מהכתפיים', 'גוף בקו ישר מהראש עד העקבים', 'יורדים עד שהחזה כמעט נוגע ברצפה', 'אם קשה — אפשר לרדת על הברכיים']::text[]),
  ('itamar', 'home-03', 'home', 2, 'גשר ישבן (Glute Bridge)', 3, '15', false, 0, 'bodyweight', 'back', ARRAY['glutes']::text[], ARRAY['hamstrings']::text[], false, ARRAY['כפות רגליים קרובות לישבן, ברוחב כתפיים', 'דוחפים דרך העקבים ומרימים את האגן', 'כיווץ חזק של הישבן למעלה, בלי לקשת בגב', 'ירידה מבוקרת, לא נופלים']::text[]),
  ('itamar', 'home-04', 'home', 3, 'לאנג׳ (Lunge)', 3, '10 לרגל', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], false, ARRAY['צעד גדול מספיק כדי לשמור על יציבות', 'ברך קדמית לא נופלת פנימה', 'ברך אחורית יורדת בשליטה, כמעט נוגעת ברצפה', 'גו זקוף לאורך כל התנועה']::text[]),
  ('itamar', 'home-05', 'home', 4, 'סופרמן (Superman)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['lowerBack']::text[], ARRAY['glutes']::text[], false, ARRAY['שוכבים על הבטן, ידיים ורגליים ישרות', 'מרימים בו־זמנית ידיים, חזה ורגליים', 'עוצרים רגע למעלה — כיווץ בגב התחתון ובישבן', 'ירידה מבוקרת, לא נופלים בבת אחת']::text[]),
  ('itamar', 'home-06', 'home', 5, 'שכיבות סמיכה צרות (Diamond Push-ups)', 3, '10', false, 0, 'bodyweight', 'back', ARRAY['triceps']::text[], ARRAY['chest']::text[], false, ARRAY['ידיים קרובות מתחת לחזה, אצבעות יוצרות משולש', 'מרפקים נשארים קרובים לגוף', 'יורדים עד שהחזה כמעט נוגע בידיים', 'אם קשה — אפשר לרדת על הברכיים']::text[]),
  ('itamar', 'home-07', 'home', 6, 'פלאנק (Plank)', 3, '40 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['obliques', 'lowerBack']::text[], false, ARRAY['קו ישר מהראש עד העקבים', 'בטן וישבן מכווצים, אין שקיעה באגן', 'המרפקים בדיוק מתחת לכתפיים', 'נושמים באופן קבוע — לא עוצרים נשימה']::text[]),
  ('itamar', 'home-p1', 'home', 7, 'שכיבות סמיכה פייק (Pike Push-ups)', 3, '10', false, 0, 'bodyweight', 'front', ARRAY['shoulders']::text[], ARRAY['triceps']::text[], true, ARRAY['ישבן גבוה, הגוף יוצר צורת V הפוכה', 'יורדים עם הראש לכיוון הרצפה בין הידיים', 'המרפקים נשארים קרובים, לא מתפרשים החוצה', 'ככל שהרגליים גבוהות יותר — קשה יותר']::text[]),
  ('itamar', 'home-p2', 'home', 8, 'מקבילים על כיסא (Bench Dips)', 3, '12', false, 0, 'bodyweight', 'back', ARRAY['triceps']::text[], ARRAY['chest']::text[], true, ARRAY['ידיים על ספסל יציב מאחורי הגוף, אצבעות קדימה', 'יורדים עד שהמרפק בערך ב־90 מעלות', 'הכתפיים לא נדחפות לכיוון האוזניים', 'אם קשה — מקרבים את הרגליים לגוף']::text[]),
  ('itamar', 'home-p3', 'home', 9, 'ישיבת קיר (Wall Sit)', 3, '45 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['glutes']::text[], true, ARRAY['גב צמוד לקיר, ברכיים בזווית 90 מעלות', 'המשקל על העקבים, לא על הבהונות', 'לא נשענים עם הידיים על הירכיים', 'נושמים רגיל — הזמן עובר לאט יותר בלי אוויר']::text[]),
  ('itamar', 'home-p4', 'home', 10, 'גשר ישבן על רגל אחת', 3, '12 לרגל', false, 0, 'bodyweight', 'back', ARRAY['glutes']::text[], ARRAY['hamstrings']::text[], true, ARRAY['רגל אחת באוויר, השנייה עם כף רגל על הרצפה', 'מרימים את האגן דרך העקב של הרגל התומכת', 'האגן נשאר ישר — לא נופל לצד', 'עצירה למעלה ואז ירידה איטית']::text[]),
  ('itamar', 'home-p5', 'home', 11, 'בורפי (Burpee)', 3, '10', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['chest', 'abs']::text[], true, ARRAY['מתחילים בעמידה, יורדים לשכיבת סמיכה', 'הגב לא מתעגל בזמן הירידה', 'קמים ומסיימים בקפיצה קלה', 'אפשר לוותר על הקפיצה ולעשות צעד במקום']::text[]),
  ('itamar', 'home-p6', 'home', 12, 'קפיצות פישוק (Jumping Jacks)', 3, '40 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['calves']::text[], ARRAY['shoulders']::text[], true, ARRAY['קפיצה קלה, נחיתה רכה על כרית כף הרגל', 'ידיים עולות עד מעל הראש', 'קצב קבוע לאורך כל הסט', 'אם הברכיים רגישות — עושים גרסת צעד במקום קפיצה']::text[]),
  ('itamar', 'home-p7', 'home', 13, 'פלאנק צידי (Side Plank)', 3, '25 שנ׳ לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], true, ARRAY['קו ישר מהראש ועד כפות הרגליים בצד', 'האגן לא שוקע ולא מתרומם יותר מדי', 'המרפק בדיוק מתחת לכתף', 'מתחלפים צד אחרי המנוחה']::text[]),
  ('itamar', 'home-p8', 'home', 14, 'בטן אלכסונית (Russian Twist)', 3, '15 לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['abs']::text[], true, ARRAY['גב ישר בהטיה, לא מתעגל', 'התנועה מגיעה מהליבה, לא מהידיים', 'אפשר להשאיר כפות רגליים על הרצפה בהתחלה', 'נושמים באופן קבוע לאורך התרגיל']::text[])
  on conflict (profile_id, ex_key) do update set program_id=excluded.program_id,
    sort_order=excluded.sort_order, name=excluded.name, target_sets=excluded.target_sets,
    target_reps=excluded.target_reps, weighted=excluded.weighted, increment=excluded.increment,
    equipment=excluded.equipment, body_view=excluded.body_view, muscles=excluded.muscles,
    muscles_sec=excluded.muscles_sec, in_pool=excluded.in_pool, cues=excluded.cues;
insert into cardio_state (profile_id, kind) values
  ('itamar', 'running'),
  ('itamar', 'cycling'),
  ('itamar', 'football'),
  ('itamar', 'basketball'),
  ('itamar', 'tennis'),
  ('itamar', 'swimming'),
  ('itamar', 'walking'),
  ('itamar', 'jumprope')
  on conflict do nothing;
insert into app_settings (profile_id, k, v) values
  ('itamar', 'prefs', '{"hidden":{},"added":{},"plan":{}}'::jsonb)
  on conflict do nothing;
insert into exercise_state (profile_id, ex_key)
  select profile_id, ex_key from exercises where profile_id = 'itamar'
  on conflict do nothing;

-- =====================================================================
-- 9. optional: clean out the old plans
--    Only run this once you are sure you no longer want the pre-v2 history
--    from gym / A / B / C / D. Deleting a program cascades to its exercises,
--    but NOT to workout_sets, so past sets survive either way.
-- =====================================================================
-- delete from programs where id in ('gym','A','B','C','D');

