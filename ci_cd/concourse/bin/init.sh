#!/usr/bin/env bash

set -e

if [ -n "$APP_DIR" ]; then
  cd $APP_DIR
fi

export BASE_DIR=$(pwd)
cd $BASE_DIR
