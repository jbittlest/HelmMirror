# START HERE

Your Garmin fishfinder screen, on your phone.

Your Mac does the hard part and hands the picture to your phone over Wi-Fi.
Nothing gets installed on the phone — you just open a web page and save it to
your home screen once.

---

## STEP 1 — Test it at home (2 minutes, no boat needed)

**On the Mac**, open Terminal and paste these two lines:

```bash
cd "/Users/jimmybittleston/Desktop/Claude Assistant/HelmMirror"
swift run helmbridge --demo
```

It prints an address, like `http://192.168.1.200:8080`.

**On your iPhone:**

1. Join the same Wi-Fi as the Mac.
2. Open **Safari** and type in the address it printed.
3. You should see colour bars with a moving timer. That is a fake video that
   proves everything works.
4. Tap the **Share** button, then **Add to Home Screen**, then **Add**.

You now have a HelmMirror icon on your phone. That is the app. You never have
to install anything on the phone again.

Press **Control-C** in Terminal to stop.

---

## STEP 2 — On the boat

**On the Mac:**

```bash
cd "/Users/jimmybittleston/Desktop/Claude Assistant/HelmMirror"
swift run helmbridge
```

(No `--demo` this time. That is the only difference.)

**Then:**

1. Put the **Mac and the phone both on the plotter's Wi-Fi**.
2. Read the address Terminal prints. It will **not** be the same as at home —
   on the boat it will look more like `172.16.6.x`.
3. **On the plotter**, one time only:
   `Settings > Communications > Wi-Fi Network > Wi-Fi Devices`
   When **HelmMirror** appears, choose **"View and Control"**.
4. **On the phone**, tap the HelmMirror icon, type in the address Terminal
   printed, tap **Connect**.

The sonar appears. Tapping the phone screen controls the plotter.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| Phone can't reach the Mac | Make sure both are on the *same* Wi-Fi, and that you typed the address Terminal printed. |
| "Bridge running, no plotter" | The Mac is not on the plotter's Wi-Fi, or the plotter is off. |
| Connects, then drops | You skipped the "View and Control" approval on the plotter. Do step 3 above. |
| Phone still can't see it | Some Wi-Fi blocks device-to-device traffic. Run `swift run helmbridge --play` and the mirror opens on the Mac itself instead. |
| `ffmpeg not found` | Run `brew install ffmpeg`. |

---

## All the options

```
swift run helmbridge              normal use, on the boat
swift run helmbridge --demo       test picture, no plotter needed
swift run helmbridge --play       show the mirror on this Mac, not the phone
swift run helmbridge --port 9000  use a different port
swift run helmbridge --host <ip>  skip searching, use this plotter address
swift run helmbridge --help       list the options
```

---

## Two links, and what each one is for

| Link | What it is |
|---|---|
| https://github.com/jbittlest/HelmMirror | The **source code**. Not for your phone. |
| The address Terminal prints | The **app**. This is the one you open on your phone. |

There is no permanent web address for the app, because the video comes out of
your own Mac. The address changes with whatever Wi-Fi you are on — that is why
the Terminal prints it every time you start.

---

## Honest status

- The wire protocol is verified: 43 byte-level tests pass (`swift run helmverify`).
- The bridge is verified end to end in `--demo` mode: real H.264 video served
  and played in a browser.
- **It has never been run against an actual Garmin.** The protocol was
  reverse-engineered from a GPSMAP 923xsv. Your plotter is the first real test.

If it fails on the boat, the *way* it fails tells us a lot:

- No plotter found → discovery / Wi-Fi
- Found but never connects → the "View and Control" approval
- Connects then drops → the subscribe indices differ on your model
- Connects but no picture → video / ffmpeg

Note which one happens and it can be fixed from there.

---

*Unofficial. Not endorsed by Garmin. Do not rely on it for navigation or
safety — keep using the real plotter for that.*
