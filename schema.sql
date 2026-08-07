-- =====================================================================
-- Icon4U — Supabase schema
-- Run this once in the Supabase SQL editor (Database > SQL Editor > New query).
-- Safe to re-run: it drops and recreates the catalog, and keeps logged data.
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
  id          text not null,                 -- 'gym' | 'home' | 'cardio' | 'A'...
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
  ex_key       text not null,                -- stable slug, e.g. 'gym-01'
  program_id   text not null,
  sort_order   int  not null,
  name         text not null,
  target_sets  int  not null,
  target_reps  text not null,                -- '10' or '30 שנ׳'
  weighted     boolean not null default true,
  increment    numeric not null default 2.5, -- how much to add when ready
  equipment    text,
  body_view    text,                         -- 'front' | 'back'
  muscles      text[] not null default '{}',
  cues         text[] not null default '{}',
  primary key (profile_id, ex_key),
  foreign key (profile_id, program_id) references programs(profile_id, id) on delete cascade
);

-- ---------- 3. the weight each person is currently working with ----------
-- This is what makes the app remember "what we set" for every exercise.
create table if not exists exercise_state (
  profile_id     text not null references profiles(id) on delete cascade,
  ex_key         text not null,
  current_weight numeric,
  updated_at     timestamptz not null default now(),
  primary key (profile_id, ex_key)
);

-- ---------- 4. what actually happened ----------
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
  kind        text not null,                 -- 'running' | 'cycling'
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
  rpe         text not null default 'ok',    -- 'easy' | 'ok' | 'hard'
  created_at  timestamptz not null default now()
);

create table if not exists daily_log (
  profile_id  text not null references profiles(id) on delete cascade,
  date        date not null,
  steps       int,
  body_weight numeric,
  primary key (profile_id, date)
);

create index if not exists idx_sets_profile_date on workout_sets (profile_id, date);
create index if not exists idx_cardio_profile_date on cardio_log (profile_id, date);

-- ---------- 5. handy views ----------
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

-- ---------- 6. row level security ----------
-- The app has no login: both phones use the public anon key. These policies
-- keep the tables reachable with that key but nothing else in the project is.
-- See the README for how to lock this down further if you ever want to.
alter table profiles       enable row level security;
alter table programs       enable row level security;
alter table exercises      enable row level security;
alter table exercise_state enable row level security;
alter table workouts       enable row level security;
alter table workout_sets   enable row level security;
alter table cardio_state   enable row level security;
alter table cardio_log     enable row level security;
alter table daily_log      enable row level security;

do $$
declare t text;
begin
  foreach t in array array['profiles','programs','exercises','exercise_state',
                           'workouts','workout_sets','cardio_state','cardio_log','daily_log']
  loop
    execute format('drop policy if exists anon_read on %I', t);
    execute format('drop policy if exists anon_write on %I', t);
    execute format('create policy anon_read  on %I for select to anon using (true)', t);
    execute format('create policy anon_write on %I for all    to anon using (true) with check (true)', t);
  end loop;
end $$;

-- =====================================================================
-- 7. seed: the two profiles and their training plans
-- =====================================================================

-- ---------- יונתן ----------
insert into profiles (id, name, accent, goal, week_goal) values
  ('yonatan', 'יונתן', '#5EE7FF', 'ירידה בשומן + עלייה במסת שריר', 4)
  on conflict (id) do update set name=excluded.name, accent=excluded.accent,
    goal=excluded.goal, week_goal=excluded.week_goal;
insert into programs (profile_id, id, label, sub, icon, hex, kind, sort_order) values
  ('yonatan', 'gym', 'חדר כושר', 'כל הגוף', '🏋️', '#FF4D6D', 'strength', 0),
  ('yonatan', 'home', 'אימון ביתי', 'כל הגוף', '🏠', '#2FE6A7', 'strength', 1),
  ('yonatan', 'cardio', 'אירובי', 'ריצה / אופניים', '🏃', '#3DA9FC', 'cardio', 2)
  on conflict (profile_id, id) do update set label=excluded.label, sub=excluded.sub,
    icon=excluded.icon, hex=excluded.hex, kind=excluded.kind, sort_order=excluded.sort_order;
insert into exercises (profile_id, ex_key, program_id, sort_order, name, target_sets,
                       target_reps, weighted, increment, equipment, body_view, muscles, cues) values
  ('yonatan', 'gym-01', 'gym', 0, 'סקוואט עם משקולת / לחיצת רגליים', 3, '10', true, 5, 'machine', 'front', ARRAY['quads']::text[], ARRAY['כפות הרגליים ברוחב כתפיים על המשטח', 'לא נועלים ברכיים בחוזקה בקצה העלייה', 'לא מרימים את הישבן מהמושב בירידה', 'שליטה מלאה בשני הכיוונים']::text[]),
  ('yonatan', 'gym-02', 'gym', 1, 'לחיצת חזה במכונה (Chest Press)', 3, '10', true, 2.5, 'machine', 'front', ARRAY['chest']::text[], ARRAY['מכוונים גובה מושב כך שהידיות בגובה החזה', 'דוחפים קדימה בשליטה, בלי לנעול מרפקים בסוף', 'חוזרים לאט לנקודת ההתחלה', 'גב צמוד למשענת לאורך כל התנועה']::text[]),
  ('yonatan', 'gym-03', 'gym', 2, 'פולי עליון (Lat Pulldown)', 3, '10', true, 2.5, 'cable', 'back', ARRAY['lats']::text[], ARRAY['אחיזה מעט רחבה מהכתפיים', 'מושכים את המרפקים למטה ואחורה, החזה מוביל', 'לא מתנופפים אחורה עם הגוף', 'עוצרים רגע למטה ואז חוזרים בשליטה']::text[]),
  ('yonatan', 'gym-04', 'gym', 3, 'לחיצת כתפיים בישיבה (Shoulder Press)', 2, '10', true, 2, 'dumbbell', 'front', ARRAY['shoulders']::text[], ARRAY['גב תחתון צמוד למשענת, בטן מכווצת קלות', 'דוחפים למעלה בלי לקשת יתר בגב', 'לא נועלים מרפקים בחוזקה למעלה', 'מורידים עד שהמרפקים בערך בגובה הכתפיים']::text[]),
  ('yonatan', 'gym-05', 'gym', 4, 'דדליפט רומני (RDL)', 2, '10', true, 2.5, 'dumbbell', 'back', ARRAY['hamstrings', 'glutes']::text[], ARRAY['ברכיים כמעט ישרות עם כפיפה קלה בלבד', 'מרימים את האגן אחורה, לא כופפים את הגב', 'המשקולות נשארות קרובות לרגליים', 'עוצרים כשמרגישים מתיחה בירך האחורית']::text[]),
  ('yonatan', 'gym-06', 'gym', 5, 'כפיפת מרפקים במוט (בייספס)', 2, '10', true, 2.5, 'barbell', 'front', ARRAY['biceps']::text[], ARRAY['אחיזה ברוחב כתפיים בערך', 'מרפקים צמודים לצדי הגוף', 'עולים בשליטה, לא בתנופת גב', 'ירידה איטית — כאן קורה הרוב']::text[]),
  ('yonatan', 'gym-07', 'gym', 6, 'טרייספס בפולי (Triceps Pushdown)', 2, '12', true, 2.5, 'cable', 'back', ARRAY['triceps']::text[], ARRAY['מרפקים צמודים לגוף וקבועים במקום', 'רק האמה זזה, לא הכתף', 'מיישרים עד הסוף בלי לנעול בחוזקה', 'חוזרים באיטיות למעלה']::text[]),
  ('yonatan', 'gym-08', 'gym', 7, 'פלאנק (Plank)', 2, '30 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['קו ישר מהראש עד העקבים', 'בטן וישבן מכווצים, אין שקיעה באגן', 'מסתכלים מעט קדימה, לא למטה לחלוטין', 'נושמים באופן קבוע — לא עוצרים נשימה']::text[]),
  ('yonatan', 'home-01', 'home', 0, 'סקוואט (Bodyweight Squat)', 3, '15', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['רגליים ברוחב כתפיים, בהונות מעט כלפי חוץ', 'יורדים כאילו יושבים על כיסא, ברכיים בקו עם הבהונות', 'גב ישר, מבט קדימה', 'דוחפים דרך העקבים לחזרה למעלה']::text[]),
  ('yonatan', 'home-02', 'home', 1, 'שכיבות סמיכה (Push-ups)', 3, '10', false, 0, 'bodyweight', 'front', ARRAY['chest']::text[], ARRAY['ידיים קצת רחבות מהכתפיים', 'גוף בקו ישר מהראש עד העקבים לאורך כל התנועה', 'יורדים עד שהחזה כמעט נוגע ברצפה', 'אם קשה — אפשר לרדת על הברכיים']::text[]),
  ('yonatan', 'home-03', 'home', 2, 'גשר ישבן (Glute Bridge)', 3, '15', false, 0, 'bodyweight', 'back', ARRAY['glutes']::text[], ARRAY['כפות רגליים קרובות לישבן, ברוחב כתפיים', 'דוחפים דרך העקבים ומרימים את האגן למעלה', 'למעלה — כיווץ חזק של הישבן, בלי לקשת יתר בגב', 'ירידה מבוקרת, לא נופלים']::text[]),
  ('yonatan', 'home-04', 'home', 3, 'לאנג׳ (Lunge)', 2, '10 לרגל', false, 0, 'bodyweight', 'front', ARRAY['quads']::text[], ARRAY['צעד מספיק גדול לשמור על יציבות', 'ברך קדמית לא נופלת פנימה ולא עוברת הרבה את הבהונות', 'ברך אחורית יורדת בשליטה, כמעט נוגעת ברצפה', 'גו זקוף לאורך כל התנועה']::text[]),
  ('yonatan', 'home-05', 'home', 4, 'סופרמן (Superman)', 2, '12', false, 0, 'bodyweight', 'back', ARRAY['lowerBack']::text[], ARRAY['שוכבים על הבטן, ידיים ורגליים ישרות', 'מרימים בו־זמנית ידיים, חזה ורגליים מהרצפה', 'עוצרים רגע למעלה, כיווץ בגב התחתון ובישבן', 'ירידה מבוקרת, לא נופלים בבת אחת']::text[]),
  ('yonatan', 'home-06', 'home', 5, 'שכיבות סמיכה צרות (Diamond Push-ups)', 2, '8', false, 0, 'bodyweight', 'back', ARRAY['triceps']::text[], ARRAY['ידיים קרובות זו לזו מתחת לחזה, אצבעות יוצרות משולש', 'מרפקים נשארים קרובים לגוף לאורך התנועה', 'יורדים עד שהחזה כמעט נוגע בידיים', 'אם קשה — אפשר לרדת על הברכיים']::text[]),
  ('yonatan', 'home-07', 'home', 6, 'פלאנק (Plank)', 2, '30 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['קו ישר מהראש עד העקבים', 'בטן וישבן מכווצים, אין שקיעה באגן', 'מסתכלים מעט קדימה, לא למטה לחלוטין', 'נושמים באופן קבוע — לא עוצרים נשימה']::text[]),
  ('yonatan', 'home-08', 'home', 7, 'בטן אלכסונית — Russian Twist', 2, '15 לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['גב ישר בהטיה, לא מתעגל', 'תנועה מבוקרת מהליבה, לא מהידיים', 'כפות רגליים יכולות להישאר על הרצפה למתחילים', 'נושמים באופן קבוע לאורך התרגיל']::text[])
  on conflict (profile_id, ex_key) do update set program_id=excluded.program_id,
    sort_order=excluded.sort_order, name=excluded.name, target_sets=excluded.target_sets,
    target_reps=excluded.target_reps, weighted=excluded.weighted, increment=excluded.increment,
    equipment=excluded.equipment, body_view=excluded.body_view, muscles=excluded.muscles,
    cues=excluded.cues;
insert into cardio_state (profile_id, kind) values
  ('yonatan', 'running'),
  ('yonatan', 'cycling')
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
  ('itamar', 'A', 'עליון א׳', 'עליון א׳', '🅐', '#FF4D6D', 'strength', 0),
  ('itamar', 'B', 'תחתון א׳', 'תחתון א׳', '🅑', '#3DA9FC', 'strength', 1),
  ('itamar', 'C', 'עליון ב׳', 'עליון ב׳', '🅒', '#FFD23F', 'strength', 2),
  ('itamar', 'D', 'תחתון ב׳', 'תחתון ב׳', '🅓', '#2FE6A7', 'strength', 3)
  on conflict (profile_id, id) do update set label=excluded.label, sub=excluded.sub,
    icon=excluded.icon, hex=excluded.hex, kind=excluded.kind, sort_order=excluded.sort_order;
insert into exercises (profile_id, ex_key, program_id, sort_order, name, target_sets,
                       target_reps, weighted, increment, equipment, body_view, muscles, cues) values
  ('itamar', 'A-01', 'A', 0, 'לחיצת חזה במכונה (Chest Press)', 3, '10', true, 2.5, 'machine', 'front', ARRAY['chest']::text[], ARRAY['מכוונים גובה מושב כך שהידיות בגובה החזה', 'דוחפים קדימה בשליטה, בלי לנעול מרפקים בסוף', 'חוזרים לאט לנקודת ההתחלה', 'גב צמוד למשענת לאורך כל התנועה']::text[]),
  ('itamar', 'A-02', 'A', 1, 'פולי עליון (Lat Pulldown)', 3, '10', true, 2.5, 'cable', 'back', ARRAY['lats']::text[], ARRAY['אחיזה מעט רחבה מהכתפיים', 'מושכים את המרפקים למטה ואחורה, החזה מוביל', 'לא מתנופפים אחורה עם הגוף', 'עוצרים רגע למטה ואז חוזרים בשליטה']::text[]),
  ('itamar', 'A-03', 'A', 2, 'חתירה בישיבה (Seated Row)', 3, '10', true, 2.5, 'cable', 'back', ARRAY['lats', 'traps']::text[], ARRAY['גב זקוף, לא מתכופפים קדימה עם המשיכה', 'מושכים מרפקים אחורה, מקרבים שכמות', 'לא מתנדנדים עם הגוף כדי לעזור למשקל', 'עצירה קצרה כשהידיים קרובות לגוף']::text[]),
  ('itamar', 'A-04', 'A', 3, 'לחיצת כתפיים בישיבה (Shoulder Press)', 2, '10', true, 2, 'dumbbell', 'front', ARRAY['shoulders']::text[], ARRAY['גב תחתון צמוד למשענת, בטן מכווצת קלות', 'דוחפים למעלה בלי לקשת יתר בגב', 'לא נועלים מרפקים בחוזקה למעלה', 'מורידים עד שהמרפקים בערך בגובה הכתפיים']::text[]),
  ('itamar', 'A-05', 'A', 4, 'כפיפת מרפקים במשקולות (בייספס)', 2, '10', true, 2, 'dumbbell', 'front', ARRAY['biceps']::text[], ARRAY['מרפקים צמודים לגוף לאורך כל התנועה', 'אפשר להחליף ידיים לסירוגין או יחד', 'עלייה בשליטה, ירידה איטית עוד יותר', 'לא מתנדנדים עם הגוף כדי לעזור']::text[]),
  ('itamar', 'A-06', 'A', 5, 'טרייספס בפולי (Triceps Pushdown)', 2, '12', true, 2.5, 'cable', 'back', ARRAY['triceps']::text[], ARRAY['מרפקים צמודים לגוף וקבועים במקום', 'רק האמה זזה, לא הכתף', 'פושטים עד הסוף בלי לנעול בחוזקה', 'חוזרים באיטיות למעלה']::text[]),
  ('itamar', 'A-07', 'A', 6, 'בטן בכבל בכריעה (Cable Crunch)', 3, '15', true, 2.5, 'cable', 'front', ARRAY['abs']::text[], ARRAY['כורעים מול הכבל, ידיים ליד הראש', 'מכופפים מהבטן, לא מהידיים או מהגב התחתון', 'האגן נשאר יציב, לא זז אחורה', 'חזרה מבוקרת למעלה בלי לאבד מתח בבטן']::text[]),
  ('itamar', 'A-08', 'A', 7, 'פלאנק (Plank)', 2, '30 שנ׳', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['קו ישר מהראש עד העקבים', 'בטן וישבן מכווצים, אין שקיעה באגן', 'מסתכלים מעט קדימה, לא למטה לחלוטין', 'נושמים באופן קבוע — לא עוצרים נשימה']::text[]),
  ('itamar', 'B-01', 'B', 0, 'לחיצת רגליים (Leg Press)', 3, '10', true, 5, 'machine', 'front', ARRAY['quads']::text[], ARRAY['כפות הרגליים ברוחב כתפיים על המשטח', 'לא נועלים ברכיים בחוזקה בקצה העלייה', 'לא מרימים את הישבן מהמושב בירידה', 'שליטה מלאה בשני הכיוונים']::text[]),
  ('itamar', 'B-02', 'B', 1, 'דדליפט רומני (RDL)', 3, '8', true, 2.5, 'dumbbell', 'back', ARRAY['hamstrings', 'glutes']::text[], ARRAY['ברכיים כמעט ישרות עם כפיפה קלה בלבד', 'מרימים את האגן אחורה, לא כופפים את הגב', 'המשקולות נשארות קרובות לרגליים', 'עוצרים כשמרגישים מתיחה בירך האחורית']::text[]),
  ('itamar', 'B-03', 'B', 2, 'יישור רגליים במכונה (Leg Extension)', 2, '12', true, 2.5, 'machine', 'front', ARRAY['quads']::text[], ARRAY['גב צמוד למשענת, לא מתרומם', 'תנועה חלקה עד כמעט יישור מלא', 'עצירה קלה למעלה, לא בעיטה מהירה', 'חזרה איטית יותר מהעלייה']::text[]),
  ('itamar', 'B-04', 'B', 3, 'כיפוף רגליים שוכב (Leg Curl)', 2, '12', true, 2.5, 'machine', 'back', ARRAY['hamstrings']::text[], ARRAY['האגן צמוד למשטח לאורך כל התנועה', 'כיפוף עד הסוף בלי לנתק את הירכיים', 'חזרה איטית ומבוקרת למטה', 'לא מסיימים בתנופה בתחתית התנועה']::text[]),
  ('itamar', 'B-05', 'B', 4, 'הרמות עקבים — עמידה (Calf Raise)', 3, '15', true, 5, 'machine', 'back', ARRAY['calves']::text[], ARRAY['עולים על קצות האצבעות בשליטה, לא בקפיצה', 'עצירה קלה למעלה', 'יורדים עד מתיחה קלה בשוק', 'אפשר להיעזר במשטח יציב לאיזון']::text[]),
  ('itamar', 'B-06', 'B', 5, 'Dead bug (תרגיל בטן)', 2, '10 לצד', false, 0, 'bodyweight', 'front', ARRAY['abs']::text[], ARRAY['גב תחתון צמוד לרצפה לאורך כל התרגיל', 'פושטים יד ורגל נגדיות באיטיות', 'נושמים כרגיל, לא עוצרים נשימה', 'אם הגב מתרומם — מקטינים את הטווח']::text[]),
  ('itamar', 'C-01', 'C', 0, 'פרפר לחזה במכונה (Chest Fly)', 3, '12', true, 2.5, 'machine', 'front', ARRAY['chest']::text[], ARRAY['כוונון מושב כך שהידיות בגובה הכתפיים', 'מקרבים ידיים בתנועה מבוקרת, בלי לנעול מרפקים', 'לא זורקים את המשקל בחזרה החוצה', 'מרגישים מתיחה קלה בחזה בפתיחה, לא כאב']::text[]),
  ('itamar', 'C-02', 'C', 1, 'חתירה במכונה (Machine Row)', 3, '10', true, 2.5, 'machine', 'back', ARRAY['lats', 'traps']::text[], ARRAY['חזה צמוד לכרית התמיכה אם קיימת', 'מושכים מרפקים אחורה, שכמות מתקרבות', 'לא מרימים כתפיים לכיוון האוזניים', 'חזרה איטית קדימה בשליטה']::text[]),
  ('itamar', 'C-03', 'C', 2, 'כפיפת מרפק פטיש', 2, '10', true, 2, 'dumbbell', 'front', ARRAY['biceps']::text[], ARRAY['אחיזה ניטרלית, האגודלים כלפי מעלה', 'מרפקים צמודים לגוף', 'עלייה בשליטה, ירידה איטית עוד יותר', 'לא מנענעים את הגוף כדי לעזור']::text[]),
  ('itamar', 'C-04', 'C', 3, 'טרייספס מעל הראש בכבל (Overhead Extension)', 2, '12', true, 2.5, 'cable', 'back', ARRAY['triceps']::text[], ARRAY['מרפקים קרובים לראש וקבועים במקום', 'מיישרים כמעט עד הסוף', 'לא מרחיקים את המרפקים הצידה', 'תנועה מבוקרת בשני הכיוונים']::text[]),
  ('itamar', 'C-05', 'C', 4, 'הרמות צד לכתפיים (Lateral Raise)', 2, '12', true, 1, 'dumbbell', 'front', ARRAY['shoulders']::text[], ARRAY['מרפקים בכיפוף קל קבוע', 'מרימים עד גובה הכתפיים בערך, לא יותר', 'תנועה איטית, בלי תנופה מהגוף', 'ירידה מבוקרת — לא נופל למטה']::text[]),
  ('itamar', 'C-06', 'C', 5, 'Russian Twist (תרגיל בטן)', 2, '15 לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['גב ישר בהטיה, לא מתעגל', 'תנועה מבוקרת מהליבה, לא מהידיים', 'כפות רגליים יכולות להישאר על הרצפה למתחילים', 'נושמים באופן קבוע לאורך התרגיל']::text[]),
  ('itamar', 'D-01', 'D', 0, 'סקוואט עם משקולת (Goblet Squat)', 3, '10', true, 2.5, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['רגליים ברוחב כתפיים, בהונות מעט כלפי חוץ', 'ברכיים בקו עם הבהונות, לא נופלות פנימה', 'יורדים עד שהירכיים בערך מקבילות לרצפה', 'משקל על כל כף הרגל, גב ישר לאורך התנועה']::text[]),
  ('itamar', 'D-02', 'D', 1, 'היפ תראסט (Hip Thrust)', 3, '10', true, 5, 'dumbbell', 'back', ARRAY['glutes']::text[], ARRAY['כתפיים עליונות נשענות על ספסל יציב', 'דוחפים דרך העקבים, לא דרך הבהונות', 'למעלה — גוף בקו ישר מהברכיים לכתפיים', 'ירידה מבוקרת, לא נופלים למטה']::text[]),
  ('itamar', 'D-03', 'D', 2, 'לאנג׳ הליכה (Walking Lunge)', 2, '10 לרגל', true, 2, 'dumbbell', 'front', ARRAY['quads']::text[], ARRAY['צעד מספיק גדול לשמור על יציבות', 'ברך קדמית לא נופלת פנימה ולא עוברת הרבה את הבהונות', 'ברך אחורית יורדת בשליטה, כמעט נוגעת ברצפה', 'גו זקוף לאורך כל התנועה']::text[]),
  ('itamar', 'D-04', 'D', 3, 'הרמות עקבים — ישיבה (Calf Raise)', 3, '15', true, 2.5, 'machine', 'back', ARRAY['calves']::text[], ARRAY['עולים על קצות האצבעות בשליטה, לא בקפיצה', 'עצירה קלה למעלה', 'יורדים עד מתיחה קלה בשוק', 'אפשר להיעזר במשטח יציב לאיזון']::text[]),
  ('itamar', 'D-05', 'D', 4, 'פלאנק צידי (Side Plank)', 2, '20 שנ׳ לצד', false, 0, 'bodyweight', 'front', ARRAY['obliques']::text[], ARRAY['קו ישר מהראש ועד כפות הרגליים בצד', 'האגן לא שוקע ולא מתרומם יותר מדי', 'המרפק בדיוק מתחת לכתף', 'נושמים כרגיל, מתחלפים צד אחרי המנוחה']::text[])
  on conflict (profile_id, ex_key) do update set program_id=excluded.program_id,
    sort_order=excluded.sort_order, name=excluded.name, target_sets=excluded.target_sets,
    target_reps=excluded.target_reps, weighted=excluded.weighted, increment=excluded.increment,
    equipment=excluded.equipment, body_view=excluded.body_view, muscles=excluded.muscles,
    cues=excluded.cues;
insert into exercise_state (profile_id, ex_key)
  select profile_id, ex_key from exercises where profile_id = 'itamar'
  on conflict do nothing;

