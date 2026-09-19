#!/bin/bash
ASD=/etc/autoscript; CFG=/usr/local/etc/xray/config.json; API=127.0.0.1:10085
echo "════════ DIAGNOSA KUOTA & LIMIT IP ════════"
echo "1. Versi SC      : $(cat $ASD/version 2>/dev/null)"
echo "2. Xray          : $(systemctl is-active xray)  | Nginx: $(systemctl is-active nginx)"
echo "3. Stats di config:"
echo "   stats object  : $(jq -r 'if .stats then "ADA" else "TIDAK ADA" end' $CFG 2>/dev/null)"
echo "   statsUserUp   : $(jq -r '.policy.levels["0"].statsUserUplink // "TIDAK ADA"' $CFG 2>/dev/null)"
echo "   statsUserDown : $(jq -r '.policy.levels["0"].statsUserDownlink // "TIDAK ADA"' $CFG 2>/dev/null)"
echo "   api services  : $(jq -rc '.api.services // "TIDAK ADA"' $CFG 2>/dev/null)"
echo "   access log    : $(jq -r '.log.access // "TIDAK ADA"' $CFG 2>/dev/null)"
echo "4. Email akun di config (5 pertama):"
jq -r '[.inbounds[].settings.clients[]?.email] | unique | .[0:5] | .[]' $CFG 2>/dev/null | sed 's/^/   /'
echo "5. API statsquery (statistik saat ini, TANPA reset):"
out=$(xray api statsquery --server=$API -pattern "user>>>" 2>&1)
if echo "$out" | grep -q "stat"; then echo "$out" | jq -r '.stat[] | "   \(.name) = \(.value // 0)"' 2>/dev/null | head -8
else echo "   KOSONG atau ERROR -> $(echo "$out" | head -2 | tr '\n' ' ')"; fi
echo "6. Access log    : $([[ -f /var/log/xray/access.log ]] && echo "ADA ($(wc -l < /var/log/xray/access.log) baris)" || echo "TIDAK ADA")"
echo "   3 baris terakhir:"
tail -3 /var/log/xray/access.log 2>/dev/null | sed 's/^/   /' || echo "   (kosong)"
echo "7. Cron guard    : $(grep -c xray-guard /etc/cron.d/autoscript 2>/dev/null) baris | cron service: $(systemctl is-active cron 2>/dev/null || systemctl is-active crond 2>/dev/null)"
echo "8. File usage tersimpan:"
find $ASD/usage -type f 2>/dev/null | head -5 | while read f; do echo "   $f = $(cat $f)"; done
[[ -z "$(find $ASD/usage -type f 2>/dev/null)" ]] && echo "   (belum ada file usage sama sekali)"
echo "9. Jalankan xray-guard manual (lihat error):"
bash -x /usr/local/sbin/xray-guard 2>&1 | grep -iE "error|not found|command|usage_collect" | head -5
echo "   (selesai, exit=$?)"
echo "10. Setelah guard jalan, file usage:"
find $ASD/usage -type f 2>/dev/null | head -5 | while read f; do echo "   $f = $(cat $f)"; done
echo "═══════════════════════════════════════════"
