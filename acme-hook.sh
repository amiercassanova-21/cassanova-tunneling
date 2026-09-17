#!/bin/bash
# Hook DNS-01 acme.sh -> Worker lisensi (token CF aman di Worker, tidak di VPS)
# acme.sh memanggil: dns_cas_add <fulldomain> <txtvalue>  dan  dns_cas_rm <fulldomain> <txtvalue>
# Butuh env: CAS_LICENSE (url worker)

dns_cas_add() {
  local fulldomain="$1" txtvalue="$2"
  _cas_req "txt-add" "$fulldomain" "$txtvalue"
}
dns_cas_rm() {
  local fulldomain="$1" txtvalue="$2"
  _cas_req "txt-del" "$fulldomain" "$txtvalue"
}
_cas_req() {
  local act="$1" name="$2" value="$3" base="${CAS_LICENSE:-https://license.cassanova.my.id}"
  local out
  out=$(curl -fsS --max-time 20 -G "$base/$act" \
    --data-urlencode "name=$name" \
    --data-urlencode "value=$value" 2>/dev/null)
  echo "$out" | grep -q '"ok":true' && return 0
  echo "[hook] gagal $act untuk $name : $out" >&2
  return 1
}
