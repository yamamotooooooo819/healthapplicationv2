# API 設計書 — 健康管理アプリ(MVP / 第1段階)

このファイルは REST API の仕様書。`CLAUDE.md` の設計判断・実装ルールに従う。
DB スキーマは `schema.sql` を正とする。

---

## 0. 共通仕様(全エンドポイント共通)

### 認証
- すべてのエンドポイントは **Firebase の ID トークンによる認証が必須**(ヘルスチェックを除く)。
- リクエストヘッダ: `Authorization: Bearer <Firebase ID Token>`
- サーバーはトークンを検証し、`auth_provider_id` から `users` を特定する。
- **URL にユーザーIDを含めない。** 「ログイン中の本人のデータ」として扱う(設計方針1)。

### 共通ヘッダ
- `Content-Type: application/json`(リクエスト/レスポンスとも)

### 日付の形式
- 日付は ISO 8601 の `YYYY-MM-DD` 文字列(例: `2026-05-24`)。タイムゾーンは含めない(設計方針3)。

### エラーレスポンス形式(統一・設計方針2)
すべてのエラーは以下の形で返す。HTTP ステータスコードも併用する。

```json
{
  "error": {
    "code": "FOOD_NOT_FOUND",
    "message": "指定された食品が見つかりません"
  }
}
```

主な HTTP ステータス:
| コード | 意味 | 例 |
|---|---|---|
| 400 | リクエスト不正 | 必須項目欠落、quantity_g が 0 以下 |
| 401 | 未認証 | トークンなし・無効 |
| 403 | 権限なし | 他人のリソースへのアクセス |
| 404 | 見つからない | 該当する食品・記録なし |
| 409 | 競合 | お気に入りの重複登録(第2段階) |
| 500 | サーバーエラー | 想定外の例外 |

主なエラーコード(MVP):
`UNAUTHENTICATED` / `VALIDATION_ERROR` / `FOOD_NOT_FOUND` /
`MEAL_ENTRY_NOT_FOUND` / `FORBIDDEN`

### ページネーション(共通方針)
一覧系は `page`(0始まり)と `size` をクエリパラメータで受ける。
レスポンスは件数情報を含む共通形にする。

```json
{
  "content": [ ... ],
  "page": 0,
  "size": 20,
  "totalElements": 137,
  "totalPages": 7
}
```

---

## 1. ヘルスチェック

動作確認用。認証不要。

### `GET /api/health`
- レスポンス 200:
```json
{ "status": "ok" }
```

---

## 2. ユーザー

### `GET /api/users/me`
ログイン中のユーザー自身の情報を取得する。初回アクセス時にレコードがなければ作成してよい
(Firebase トークンの情報から `users` を upsert する想定)。

- レスポンス 200:
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "email": "user@example.com",
  "displayName": "テスト太郎"
}
```
- エラー: 401 `UNAUTHENTICATED`

---

## 3. 食品(foods)

### `GET /api/foods/search`
食品をあいまい検索する(設計: 20件ずつ・一致度順)。

- クエリパラメータ:
  - `q`(必須): 検索語。例 `?q=ごはん`
  - `page`(任意, 既定 0)
  - `size`(任意, 既定 20)
- 検索仕様:
  - `foods.name` に対する部分一致(pg_trgm)。前方一致を優先した一致度順。
  - `deleted_at IS NULL` のみ対象。
  - 文科省データ(source=mext)とユーザー登録(source=user)は出し分けず一致度順。
- レスポンス 200:
```json
{
  "content": [
    {
      "id": 1024,
      "name": "こめ [水稲めし] 精白米",
      "source": "mext",
      "proteinG": 2.50,
      "fatG": 0.30,
      "carbG": 37.10,
      "kcal": 168.00
    }
  ],
  "page": 0,
  "size": 20,
  "totalElements": 3,
  "totalPages": 1
}
```
- 補足: PFC・kcal は「100gあたり」の値(設計判断10)。
- エラー: 400 `VALIDATION_ERROR`(q が空)

### `GET /api/foods/{id}`
食品1件の詳細を取得する。

- レスポンス 200: search の content 要素1件と同じ構造。
- エラー: 404 `FOOD_NOT_FOUND`

### `POST /api/foods`
ユーザー独自の食品を登録する(`source` は強制的に `user`、`created_by` はログインユーザー)。

- リクエスト:
```json
{
  "name": "自家製プロテインバー",
  "proteinG": 20.00,
  "fatG": 8.00,
  "carbG": 30.00,
  "kcal": 280.00
}
```
- レスポンス 201: 作成された food(GET /{id} と同じ構造)。
- エラー: 400 `VALIDATION_ERROR`(name 空、PFC が負 等)

---

## 4. 食事記録(meal-entries)

### `POST /api/meal-entries`
1食分をまとめて登録する(設計方針4: 一括登録)。

**重要(設計判断6 / 実装ルール):**
リクエストでフロントが送るのは `foodId` と `quantityG` のみ。
PFC・kcal のスナップショットは**サーバー側で** `foods` マスタの100gあたり値から
`quantityG / 100` を掛けて計算し、`meal_entry_items` に保存する。
フロントの計算値は信用しない。

- リクエスト:
```json
{
  "eatenOn": "2026-05-24",
  "mealType": "breakfast",
  "items": [
    { "foodId": 1024, "quantityG": 150.0 },
    { "foodId": 2087, "quantityG": 50.0 }
  ]
}
```
- レスポンス 201(サーバーが計算したスナップショットを含めて返す):
```json
{
  "id": 5001,
  "eatenOn": "2026-05-24",
  "mealType": "breakfast",
  "items": [
    {
      "id": 9001,
      "foodId": 1024,
      "foodName": "こめ [水稲めし] 精白米",
      "quantityG": 150.0,
      "proteinG": 3.75,
      "fatG": 0.45,
      "carbG": 55.65,
      "kcal": 252.00
    }
  ]
}
```
- バリデーション: `mealType` は breakfast/lunch/dinner/snack のみ。
  `quantityG` > 0。`items` は1件以上。
- 同一食事内の同一 foodId の重複は**許可**(設計判断7)。
- エラー: 400 `VALIDATION_ERROR` / 404 `FOOD_NOT_FOUND`(items に存在しない foodId)

### `GET /api/meal-entries?date=YYYY-MM-DD`
指定日の食事記録を全区分まとめて取得する。

- クエリパラメータ: `date`(必須)
- レスポンス 200: その日の meal_entries を区分ごとに配列で返す。
```json
{
  "date": "2026-05-24",
  "entries": [
    {
      "id": 5001,
      "mealType": "breakfast",
      "items": [
        {
          "id": 9001,
          "foodId": 1024,
          "foodName": "こめ [水稲めし] 精白米",
          "quantityG": 150.0,
          "proteinG": 3.75, "fatG": 0.45, "carbG": 55.65, "kcal": 252.00
        }
      ]
    }
  ]
}
```
- `deleted_at IS NULL` のみ対象。
- エラー: 400 `VALIDATION_ERROR`(date 不正)

### `POST /api/meal-entries/{id}/items`
既存の食事記録に品目を追加する(後から1品足したい場合)。

- リクエスト:
```json
{ "foodId": 3050, "quantityG": 200.0 }
```
- レスポンス 201: 追加された item(スナップショット計算済み)。
- エラー: 404 `MEAL_ENTRY_NOT_FOUND` / 404 `FOOD_NOT_FOUND` / 403 `FORBIDDEN`(他人の記録)

---

## 5. 集計(summary)

### `GET /api/summary/daily?date=YYYY-MM-DD`
指定日の PFC を「区分別小計」と「1日合計」の両方で返す(設計判断B)。
集計は `meal_entry_items` のスナップショット値を SUM する(サーバー側集計・実装ルール)。

- クエリパラメータ: `date`(必須)
- レスポンス 200:
```json
{
  "date": "2026-05-24",
  "byMealType": {
    "breakfast": { "protein": 3.75, "fat": 0.45, "carb": 55.65, "kcal": 252.00 },
    "lunch":     { "protein": 0, "fat": 0, "carb": 0, "kcal": 0 },
    "dinner":    { "protein": 0, "fat": 0, "carb": 0, "kcal": 0 },
    "snack":     { "protein": 0, "fat": 0, "carb": 0, "kcal": 0 }
  },
  "total": { "protein": 3.75, "fat": 0.45, "carb": 55.65, "kcal": 252.00 }
}
```
- 記録がない区分は 0 で返す(フロントが4区分を常に表示できるように)。
- エラー: 400 `VALIDATION_ERROR`(date 不正)

---

## 6. 第2段階(設計予約・MVPでは実装しない)

URL 体系だけ予約しておく。詳細仕様は第2段階の着手時に決める。

- `GET/POST/DELETE /api/favorites` … お気に入り。(user_id, food_id) で一意、重複は 409。
- `GET/POST/PUT/DELETE /api/my-meals` … My食事テンプレート。
  - `POST /api/my-meals/{id}/apply` … My食事を食事記録へ展開
    (展開時に最新マスタから PFC を計算しスナップショット。設計判断8)。
- `DELETE /api/meal-entries/{id}` … 食事記録の論理削除(設計判断9)。
- `DELETE /api/foods/{id}` … ユーザー食品の論理削除。
- `GET /api/meal-entries/history?page=&size=` … 履歴一覧(ページネーション)。

---

## 7. 命名規約まとめ(Claude Code への指示)

- URL はケバブケース複数形: `/api/meal-entries`。
- JSON のキーはキャメルケース: `eatenOn`, `quantityG`, `proteinG`。
  (DBカラムは snake_case の `eaten_on` 等。境界で変換する。)
- 一覧は必ずページネーション共通形(§0)に従う。
- 認証必須エンドポイントでユーザーIDをパスに含めない。
