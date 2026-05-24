-- =============================================================================
--  健康管理アプリ  データベーススキーマ (PostgreSQL)
-- =============================================================================
--  対象: 第1段階(MVP) + 第2段階(My食事・お気に入り)
--  方針:
--    - 認証は外部サービス(Firebase / Supabase 等)を利用。パスワードは保持しない。
--    - 主キーは users のみ UUID(ID推測対策)。その他は BIGSERIAL。
--    - 栄養素は誤差を避けるため NUMERIC を使用(float は使わない)。
--    - 食事記録(meal_entry_items)は PFC をスナップショット保存し、
--      過去の記録が後から変化しないようにする。
--    - My食事(my_meal_items)は構成のみ保持し、常に最新マスタを参照する。
--    - 削除は原則として論理削除(deleted_at)。
--  前提: PostgreSQL 13 以降(gen_random_uuid は pgcrypto / 13以降は標準搭載)。
-- =============================================================================

-- gen_random_uuid() を使うための拡張(PostgreSQL 13未満の場合に必要)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 食品名のあいまい検索(任意・第1段階の検索機能で利用)
CREATE EXTENSION IF NOT EXISTS pg_trgm;


-- =============================================================================
--  1. users : ユーザー
-- =============================================================================
--  認証は外部サービスに委譲。auth_provider_id で外部アカウントと紐づける。
CREATE TABLE users (
    id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    email            VARCHAR(255) NOT NULL UNIQUE,
    auth_provider_id VARCHAR(255) NOT NULL UNIQUE,  -- 外部認証サービスのユーザーID
    display_name     VARCHAR(100),
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE  users IS 'アプリ利用者。認証情報そのものは外部サービスが管理する。';
COMMENT ON COLUMN users.auth_provider_id IS '外部認証サービス(Firebase等)が発行する一意のユーザーID。';


-- =============================================================================
--  2. foods : 食品マスタ
-- =============================================================================
--  栄養値はすべて「可食部100gあたり」で統一して保存する。
--  source で「文科省データ由来」「ユーザー登録」などを区別する。
CREATE TABLE foods (
    id         BIGINT       GENERATED ALWAYS AS IDENTITY,
    name       VARCHAR(255) NOT NULL,
    source     VARCHAR(20)  NOT NULL DEFAULT 'mext',  -- 'mext' / 'user' / 'openfoodfacts'
    protein_g  NUMERIC(6,2),   -- たんぱく質 (g / 100g)
    fat_g      NUMERIC(6,2),   -- 脂質       (g / 100g)
    carb_g     NUMERIC(6,2),   -- 炭水化物   (g / 100g)
    kcal       NUMERIC(7,2),   -- エネルギー (kcal / 100g)
    created_by UUID         REFERENCES users(id),    -- ユーザー登録食品の場合のみ
    deleted_at TIMESTAMPTZ,                          -- 論理削除
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT foods_pk PRIMARY KEY (id),
    CONSTRAINT foods_source_chk CHECK (source IN ('mext', 'user', 'openfoodfacts'))
);

COMMENT ON TABLE  foods IS '食品マスタ。栄養値は可食部100gあたり。';
COMMENT ON COLUMN foods.source IS 'データ由来: mext=文科省, user=ユーザー登録, openfoodfacts=将来用。';
COMMENT ON COLUMN foods.created_by IS 'ユーザー登録食品の作成者。マスタ由来食品ではNULL。';


-- =============================================================================
--  3. meal_entries : 食事記録(いつ・どの食事区分か)
-- =============================================================================
--  「2024-05-24 の 朝食」という単位を1行で表す。中身は meal_entry_items。
CREATE TABLE meal_entries (
    id         BIGINT       GENERATED ALWAYS AS IDENTITY,
    user_id    UUID         NOT NULL REFERENCES users(id),
    eaten_on   DATE         NOT NULL,                 -- いつの食事か
    meal_type  VARCHAR(10)  NOT NULL,                 -- breakfast / lunch / dinner / snack
    deleted_at TIMESTAMPTZ,                           -- 論理削除
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT meal_entries_pk PRIMARY KEY (id),
    CONSTRAINT meal_entries_meal_type_chk
        CHECK (meal_type IN ('breakfast', 'lunch', 'dinner', 'snack'))
);

COMMENT ON TABLE  meal_entries IS 'ある日・ある食事区分のまとまり。明細は meal_entry_items。';
COMMENT ON COLUMN meal_entries.meal_type IS 'breakfast/lunch/dinner/snack の4区分(CHECK制約)。';


-- =============================================================================
--  4. meal_entry_items : 食事記録の明細(何をどれだけ食べたか)
-- =============================================================================
--  PFC・カロリーは「食べた時点の値」をスナップショット保存する。
--  これにより、後で foods マスタの値が変わっても過去の記録は不変。
--  同一食事内での同一食品の重複は許可(おかわり等を表現)。
CREATE TABLE meal_entry_items (
    id             BIGINT       GENERATED ALWAYS AS IDENTITY,
    meal_entry_id  BIGINT       NOT NULL REFERENCES meal_entries(id) ON DELETE CASCADE,
    food_id        BIGINT       NOT NULL REFERENCES foods(id),
    quantity_g     NUMERIC(7,2) NOT NULL,             -- 実際に食べた量(g)
    -- ↓ 記録時点の実測値スナップショット(quantity_g 換算後の実数)
    protein_g_snap NUMERIC(7,2) NOT NULL,
    fat_g_snap     NUMERIC(7,2) NOT NULL,
    carb_g_snap    NUMERIC(7,2) NOT NULL,
    kcal_snap      NUMERIC(8,2) NOT NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT meal_entry_items_pk PRIMARY KEY (id),
    CONSTRAINT meal_entry_items_quantity_chk CHECK (quantity_g > 0)
);

COMMENT ON TABLE  meal_entry_items IS '食事の明細。PFC・kcalは食べた時点のスナップショット。';
COMMENT ON COLUMN meal_entry_items.protein_g_snap IS 'quantity_g 分のたんぱく質量(記録時点で確定)。';


-- =============================================================================
--  5. my_meals : My食事(よく食べる組み合わせのテンプレート)  ※第2段階
-- =============================================================================
--  日付や食事区分には紐づかない、名前付きのテンプレート。
CREATE TABLE my_meals (
    id         BIGINT       GENERATED ALWAYS AS IDENTITY,
    user_id    UUID         NOT NULL REFERENCES users(id),
    name       VARCHAR(100) NOT NULL,                 -- 例: 「いつもの朝食」
    deleted_at TIMESTAMPTZ,                           -- 論理削除
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT my_meals_pk PRIMARY KEY (id)
);

COMMENT ON TABLE my_meals IS 'ユーザー定義の食事テンプレート。栄養値は保持せず構成のみ。';


-- =============================================================================
--  6. my_meal_items : My食事の構成品目  ※第2段階
-- =============================================================================
--  スナップショットは持たない。展開時に foods から最新値を計算する。
CREATE TABLE my_meal_items (
    id         BIGINT       GENERATED ALWAYS AS IDENTITY,
    my_meal_id BIGINT       NOT NULL REFERENCES my_meals(id) ON DELETE CASCADE,
    food_id    BIGINT       NOT NULL REFERENCES foods(id),
    quantity_g NUMERIC(7,2) NOT NULL,                 -- 構成量(g)
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT my_meal_items_pk PRIMARY KEY (id),
    CONSTRAINT my_meal_items_quantity_chk CHECK (quantity_g > 0)
);

COMMENT ON TABLE  my_meal_items IS 'My食事の構成。スナップショットせず最新マスタを参照する。';
COMMENT ON COLUMN my_meal_items.quantity_g IS '構成量。食事記録へ展開する瞬間にPFCを計算する。';


-- =============================================================================
--  7. favorites : お気に入り食品  ※第2段階
-- =============================================================================
--  ユーザーと食品の多対多。同一食品の重複登録は防ぐ(UNIQUE)。
CREATE TABLE favorites (
    id         BIGINT      GENERATED ALWAYS AS IDENTITY,
    user_id    UUID        NOT NULL REFERENCES users(id),
    food_id    BIGINT      NOT NULL REFERENCES foods(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT favorites_pk PRIMARY KEY (id),
    CONSTRAINT favorites_uq UNIQUE (user_id, food_id)
);

COMMENT ON TABLE favorites IS 'お気に入り食品。(user_id, food_id) で一意。';


-- =============================================================================
--  インデックス
-- =============================================================================
--  日次・週次のPFC集計は user_id + 日付で引くため複合インデックスを張る。
CREATE INDEX idx_meal_entries_user_date
    ON meal_entries (user_id, eaten_on)
    WHERE deleted_at IS NULL;

--  食事明細は親(meal_entry_id)で必ず引くので張る。
CREATE INDEX idx_meal_entry_items_entry
    ON meal_entry_items (meal_entry_id);

--  食品検索: 名前の前方一致・あいまい検索(pg_trgm)。
CREATE INDEX idx_foods_name_trgm
    ON foods USING gin (name gin_trgm_ops)
    WHERE deleted_at IS NULL;

--  My食事・お気に入りはユーザー単位で一覧表示するため。
CREATE INDEX idx_my_meals_user      ON my_meals (user_id)  WHERE deleted_at IS NULL;
CREATE INDEX idx_my_meal_items_meal ON my_meal_items (my_meal_id);
CREATE INDEX idx_favorites_user     ON favorites (user_id);
