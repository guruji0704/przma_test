#!/bin/bash
export LANCEDB_URI="s3://perkeep/lancedb/?endpoint=https://in-maa-1.linodeobjects.com&region=in-maa-1"
export AWS_ACCESS_KEY_ID="QBQ24J1P1BV957AUYYXV"
export AWS_SECRET_ACCESS_KEY="LqqbMn1gBggICrvrqQMOKQ57T9rnqeXXOx6x8H7B"
export AWS_ENDPOINT="https://in-maa-1.linodeobjects.com"
export AWS_DEFAULT_REGION="in-maa-1"
. "$HOME/.cargo/env"
cd /app
exec mix phx.server
