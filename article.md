# 概要
Docker コンテナの原則として「1コンテナ1プロセス」[^1]というものがありますが、あえてこの原則を破りたいときがあるかもしれません。
[^1]: http://docs.docker.jp/v19.03/develop/develop-images/dockerfile_best-practices.html#decouple-applications
そんな時は、以下の Docker 公式ドキュメントを参考にすると、良いでs……**死にます**。
[コンテナー内での複数サービス起動](https://matsuand.github.io/docs.docker.jp.onthefly/config/containers/multi-service_container/)

**上記ドキュメントのラッパースクリプトを利用する方法には重大な問題があり、本番環境で使用するべきではありません。**
(よりによって「本番環境でのアプリ運用」の項目にある)

![wanada.jpg](https://qiita-image-store.s3.ap-northeast-1.amazonaws.com/0/250243/1d1dcb99-8b21-a6fd-e6ef-911d7e8fcfb3.jpeg)
> 公式ドキュメントに書かれているのに、死ぬというのはおかしいじゃないか
それが罠だという証拠

ちなみに supervisord を利用する方法は問題ありません。
また、コンテナ向けに最適化された s6-overlay[^2] を利用する方法もあります。
[^2]: https://github.com/just-containers/s6-overlay

# ラッパースクリプトの問題点

- **プロセスの graceful shutdown が実行されない(プロセスに SIGKILL が投げられ強制終了する)**
  - データベースに保存されたデータが破損することがある
  - 例として、postgres に SIGKILL が投げられると、強制終了して再起動時にリカバリ処理が入る[^3]

[^3]: https://www.postgresql.jp/document/13/html/server-shutdown.html

# 原因

ラッパースクリプトが PID1 で起動しているため、docker のコンテナ stop 時に SIGTERM をハンドリングできず、コンテナ内すべてのプロセスが強制終了する。

## もっとくわしく

<details>
<summary>linux のプロセス・シグナルの説明</summary>
<div>

- **プロセス**とは、プログラムが実行されている状態のもの
  - ls コマンドや bash スクリプトもプロセスが作られる
- プロセスは、いろいろな**シグナル**を受け取りシグナルに従ったデフォルトの処理を行う
  - SIGHUP : プロセスに再起動を通知する
  - SIGTERM : プロセスに終了を通知する
  - SIGKILL : プロセスに強制終了を通知する
  - etc...
- プログラムには、**シグナルハンドラ**というシグナルを受け取ったときの処理を作りこむことができるものがある(上記のデフォルトの処理を上書きするイメージ)
- Linux の最初のプロセス = **PID1(Process ID 1)** は慣習的に **init プロセス**が実行され、init プロセスがそのほかのいろいろなサービスプログラムを子プロセスとして実行する
  - init プロセスの例としては、systemd がある
- init プロセスが死ぬとほかのサービスプログラムも死ぬので、**PID1 プロセスはシグナルを無視し、デフォルトの処理を行わない**(PID1 となるプログラムは、明示的にシグナルハンドラを実装する必要がある)

</div>
</details>

<details>
<summary>docker コンテナの説明</summary>
<div>

- docker はコンテナを run するとき、Dockerfile の CMD のプログラムを最初のプロセス(PID1)として実行する
- docker コンテナは、PID1 プロセスが終了すると、stop 状態となる(docker ps で exit ステータスとなる)
- docker はコンテナを stop するとき、シグナル SIGTERM を PID1 プロセスに渡し、プロセスを正常終了させる
  - **SIGTERM を投げてから一定時間(デフォルトで10秒)以内に PID1 のプロセスが終了しないと、今度は SIGKILL を PID 1 のプロセスに投げる**
  - **SIGKILL は無視できないため、PID1 プロセスが強制終了する**

</div>
</details>


docker コンテナが run , stop するまでの流れを順に見ていきます。

例として、以下の二つのプロセスを1つのコンテナで起動することを考えます。

- django    : Web アプリ
- postgres  : データベース

### docker コンテナが run するまでの流れ

![run.drawio.png](https://qiita-image-store.s3.ap-northeast-1.amazonaws.com/0/250243/f02c7616-29a6-2cf7-4155-111385b3691d.png)

1. `docker compose up -d` コマンドを実行する
2. コンテナが run するとき、Dockerfile に書かれた CMD の コマンド my_wrapper_script.sh を PID1 プロセスとして実行する
3. my_wrapper_script.sh のプロセスがは django と postgres を順に子プロセスとして実行する

### docker コンテナが stop するまでの流れ

![stop.drawio.png](https://qiita-image-store.s3.ap-northeast-1.amazonaws.com/0/250243/a2e2c582-50a7-4795-68fb-fac558ef3807.png)

1. `docker compose stop` コマンドを実行する
2. コンテナが stop するとき、シグナル SIGTERM が PID1 のプロセス(my_wrapper_script.sh のプロセス)に投げられる
3. my_wrapper_script.sh のプロセスは PID1 であるため、SIGTERM を無視し、デフォルトの処理を行わない
4. 10秒後、PID1 のプロセス(my_wrapper_script.sh のプロセス)に SIGKILL が投げられる
5. my_wrapper_script.sh のプロセスは強制終了する
6. PID1 のプロセスが kill された後コンテナは停止のために、コンテナ内すべてのプロセス(django, postgres)を強制終了する

## init フラグで解消できないか?

結論としては、ダメでした。

init フラグは「シグナルハンドラを実装しない PID1 のプロセスが SIGTERM を無視する」という問題を解決するためのオプションです。
動作としては、軽量の init プロセスを PID1 で起動し、その init プロセスの子プロセスとして実行する、というものです。
しかし、init フラグで追加される init プロセスである tini は、SIGTERM を受け取ったとき**最初の子プロセスが終了すると自身のプロセスを終了する**[^4]という動作のため、結局2つ以上の子プロセスがある場合は、残りのプロセスは強制終了してしまいます。
[^4]: https://github.com/krallin/tini#understanding-tini

# 実際に試してみよう

## 事前準備
用意するものは、以下の3ファイルです。

- Dockerfile
- my_wrapper_script.sh
- docker-compose.yml


```Dockerfile:Dockerfile
# postgres のイメージを元に、django のインストール
FROM postgres:bullseye
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip
RUN python3 -m pip install Django

# プロジェクト(django_app)の作成
RUN django-admin startproject django_app
WORKDIR /django_app

# postgres と django を起動するラッパースクリプトをコピー
COPY ./my_wrapper_script.sh my_wrapper_script.sh
RUN chmod 777 my_wrapper_script.sh

# コンテナの run 時に、ラッパースクリプトを実行する
ENTRYPOINT [ "" ]
CMD ["./my_wrapper_script.sh"]
```

```bash:my_wrapper_script.sh
#!/bin/bash

# 1つめのプロセスを起動(django)
python3 manage.py runserver 0.0.0.0:8000 &

# 2つめのプロセスを起動(postgres)
docker-entrypoint.sh postgres &

# いずれかが終了するのを待つ
wait -n

# 最初に終了したプロセスのステータスを返す
exit $?
```

```yaml:docker-compose.yml
version: "3.7"

services:
  webapp:
    build:
      context: ./
    environment:
      - POSTGRES_PASSWORD=postgres
    ports:
      - "8000:8000"
      - "5433:5432"
    volumes:
      - db:/var/lib/postgresql/data

volumes:
  db:
```

ディレクトリ構造は、こんな感じ

```
django_postgres
├── docker-compose.yml
├── Dockerfile
└── my_wrapper_script.sh
```

# まとめ

いかがだったでしょうか?
公式の罠に危うく引っかかるところでしたね。(私は頭まで浸かりましたが)
1コンテナ内で複数のプロセスを動かすのは結構面倒なので、できる限り DockerHub の official image を利用し、サービスを分離したほうが良いでしょう。

