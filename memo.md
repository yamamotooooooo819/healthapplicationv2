

### 設計

DB(MVP段階)

文科省の「日本食品標準成分表」から将来的に Open Food Facts(バーコード商品データ、無料)などを組み合わせる

\_snap(スナップショット)列を作っておくことで、後から特定のpfcが変わってしまった場合に対応

朝昼晩・間食の4項目



食品API

食品検索のページネーションは一致度順に20件まで表示

朝昼晩と1日の計PFCをAPIから持ってくる(フロントで計算する必要なし)



#### 環境構築

DB構築中にpsql16のパスを通した。DBサーバーが起動していなかったので手動起動した。

DBのユーザ名は環境変数から参照する形にした{$DB\_USENAME}など



firebaseAPI:const firebaseConfig = {

&#x20; apiKey: "AIzaSyDjbmN5\_iQlh2KFJHw5wRir5\_pNjva3A6k",

&#x20; authDomain: "health-app-cdbfa.firebaseapp.com",

&#x20; projectId: "health-app-cdbfa",

&#x20; storageBucket: "health-app-cdbfa.firebasestorage.app",

&#x20; messagingSenderId: "1075649466331",

&#x20; appId: "1:1075649466331:web:70c3cf4aa8f2a3fef3a1fe",

&#x20; measurementId: "G-62D223JQ06"

};



###### frontend

lib/firebase.tsは.envを「変換」というよりも「読み込んで → Firebase が要求する形に組み立てて → Firebase に渡す」

サーバーは二つ起動しなければならないが、**URLは1つのみ!!!**

