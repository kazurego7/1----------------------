#!/bin/bash

# 1つめのプロセスを起動(django)
python3 manage.py runserver 0.0.0.0:8000 &

# 2つめのプロセスを起動(postgres)
docker-entrypoint.sh postgres &

# いずれかが終了するのを待つ
wait -n

# 最初に終了したプロセスのステータスを返す
exit $?
