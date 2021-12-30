# postgres のイメージを元に、django のインストール
FROM postgres:bullseye
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    procps
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