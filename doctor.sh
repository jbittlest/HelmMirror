#!/bin/bash
#
# doctor.sh — figure out why the phone can't load the mirror.
#
# Run this ON THE MAC while it is joined to the plotter's Wi-Fi:
#
#     ./doctor.sh 172.16.88.144
#
# where that address is your PHONE's IP (Settings > Wi-Fi > tap the (i)).
# Leave it off and it still checks everything that doesn't need the phone.
#
# It prints a verdict at the end. Screenshot it if you need to send it on.

PHONE="$1"
echo "=============================================================="
echo " HelmMirror doctor"
echo "=============================================================="

# ---------- This Mac ----------
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
MASK=$(ipconfig getoption en0 subnet_mask 2>/dev/null)
ROUTER=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
SSID=$(ipconfig getsummary en0 2>/dev/null | awk -F' SSID : ' '/ SSID/{print $2; exit}')

echo
echo "This Mac"
echo "  Wi-Fi network : ${SSID:-unknown}"
echo "  IP address    : ${IP:-NONE}"
echo "  Subnet mask   : ${MASK:-unknown}"
echo "  Router        : ${ROUTER:-unknown}"

if [ -z "$IP" ]; then
  echo
  echo "VERDICT: this Mac has no Wi-Fi address. Join the plotter's network first."
  exit 1
fi

# ---------- Is the bridge running and listening? ----------
echo
echo "Bridge"
if pgrep -f helmbridge >/dev/null; then
  echo "  helmbridge running : yes"
else
  echo "  helmbridge running : NO  <-- start it in another window first"
fi

PORT=""
for p in 8080 8081 8082 8083 8084; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN 2>/dev/null | grep -q helmbridg; then PORT=$p; break; fi
done

if [ -n "$PORT" ]; then
  echo "  listening on port  : $PORT"
else
  echo "  listening on port  : NOTHING FOUND"
fi

# ---------- Can the Mac reach its own server? ----------
if [ -n "$PORT" ]; then
  CODE=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://127.0.0.1:$PORT/")
  echo "  loads on localhost : HTTP $CODE"
  CODE2=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://$IP:$PORT/")
  echo "  loads on $IP : HTTP $CODE2"
fi

# ---------- Firewall ----------
FW=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
echo
echo "Firewall"
echo "  $FW"

# ---------- The plotter ----------
echo
echo "Plotter"
if [ -n "$ROUTER" ]; then
  if ping -c 2 -t 3 "$ROUTER" >/dev/null 2>&1; then
    echo "  ping $ROUTER : OK"
  else
    echo "  ping $ROUTER : NO REPLY"
  fi
fi

# ---------- The phone ----------
echo
echo "Phone"
if [ -z "$PHONE" ]; then
  echo "  (no phone address given — re-run as:  ./doctor.sh 172.16.88.144 )"
else
  echo "  address given : $PHONE"
  if ping -c 3 -t 3 "$PHONE" >/dev/null 2>&1; then
    PHONE_PING=yes
    echo "  ping          : OK — the Mac can reach the phone"
  else
    PHONE_PING=no
    echo "  ping          : NO REPLY"
  fi
  arp -n "$PHONE" 2>/dev/null | sed 's/^/  arp           : /'
fi

# ---------- Verdict ----------
echo
echo "=============================================================="
echo " VERDICT"
echo "=============================================================="
if [ -z "$PORT" ]; then
  echo " The bridge is not listening. Start it first:  swift run helmbridge"
elif [ "$CODE2" != "200" ]; then
  echo " The server is not reachable even from this Mac. Something is wrong"
  echo " with the bridge itself — send this output on."
elif [ -z "$PHONE" ]; then
  echo " The Mac side is healthy and serving on http://$IP:$PORT"
  echo " Re-run with your phone's IP to test the link to the phone."
elif [ "$PHONE_PING" = "yes" ]; then
  echo " The Mac can reach the phone, and the server is healthy."
  echo " On the phone open:   http://$IP:$PORT"
  echo " If that still fails it is the phone's browser, not the network."
else
  echo " The Mac is serving correctly but CANNOT reach the phone at all,"
  echo " even though both are on the same network."
  echo
  echo " That means the plotter's Wi-Fi is blocking devices from talking to"
  echo " each other (AP client isolation). No change to this software can"
  echo " get around it."
  echo
  echo " Options:"
  echo "   1. Use  swift run helmbridge --play  (mirror on the Mac). Works today."
  echo "   2. Put a cheap travel router between them: the router joins the"
  echo "      plotter's Wi-Fi, and the Mac and phone both join the router."
  echo "   3. Check the plotter for an isolation / guest-mode setting to turn off."
fi
echo
