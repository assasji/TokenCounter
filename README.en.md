# TokenCounter

🌐 **한국어**: [README.md](README.md)

TokenCounter is a tiny macOS app that shows the **remaining usage (%)** of your Claude, ChatGPT (Codex), and Gemini accounts right in the **menu bar** (the strip at the very top of your screen). You just click a login button for each service — no terminal or CLI needed for everyday use.

---

> ## ⚠️ Read this first — important warning
>
> TokenCounter is an **unofficial** tool. It is **not affiliated with or endorsed by** Anthropic (Claude), OpenAI (ChatGPT), or Google (Gemini).
>
> To read your usage, it calls **internal APIs that are not part of each service's public documentation.** This may **violate each provider's Terms of Service**, and as a result:
>
> - login/usage lookups may stop working one day without warning, and
> - **your account could be limited or suspended.** (Anthropic in particular has previously blocked similar third‑party tools.)
>
> **Use at your own risk — entirely.** Only use this if you understand and accept that risk. If you are concerned, set a **longer refresh interval (e.g. 15 minutes or more)** in Settings.

---

## What you see

- **Menu bar**: each service's icon + the remaining percentage of its shortest usage window (e.g. `43%`)
- **Click an icon**: all usage windows the account exposes (5‑hour, weekly, …) and their reset times
- **Colors**: red under 20% / yellow 20–50% / default above
- `⚠`: login required, or the last lookup failed
- `N/A`: no value has been read successfully yet

The number is not a token count or a dollar amount — it's the **remaining percentage of a usage window** as reported by each service.

---

## Install (macOS · step by step)

> TokenCounter is currently distributed **as source code**. Follow the steps below once; after that it just runs.
> (The app is not Apple‑signed, so macOS will ask once the first time you open it — see step 6.)

### Step 1. Install developer tools (one time, ~5 min)

Open `Terminal` (Applications → Utilities → Terminal), paste this, and press Enter:

```sh
xcode-select --install
```

Click **Install** if a window appears. If it says it's already installed, just continue.

> Requirement: **macOS 13 (Ventura) or later**.

### Step 2. Download the code

**Easy way (no Git needed):**
1. On this GitHub page, click the green **`Code`** button → **`Download ZIP`**
2. Double‑click the downloaded ZIP to unzip it (you'll usually get a `TokenCounter-main` folder)

**If you know Git:**
```sh
git clone https://github.com/assasji/TokenCounter.git
```

### Step 3. Go into that folder

In Terminal, type `cd ` (with a trailing space), then **drag the unzipped folder onto the Terminal window** and press Enter. Example:

```sh
cd ~/Downloads/TokenCounter-main
```

### Step 4. Build the app

```sh
./scripts/build_app.sh
```

The first build can take 1–2 minutes. When it finishes, `dist/TokenCounter.app` is created inside the folder.

### Step 5. Move it to Applications

```sh
mv dist/TokenCounter.app /Applications/
```

(Or open the `dist` folder in Finder and drag `TokenCounter.app` into `Applications`.)

### Step 6. First launch (important)

Because the app isn't Apple‑signed, double‑clicking shows an "unidentified developer" warning. **The first time only**, open it like this:

- In `Applications`, **right‑click (or Control‑click) TokenCounter → Open → Open**

After opening it once this way, it launches normally from then on. When it runs, its icon appears in the **menu bar** at the top of the screen (it does not appear in the Dock).

---

## Signing in (connecting accounts)

Click a menu‑bar icon or open **Settings…**, then press the login button for the service you want:

- **Claude**: **Claude 로그인… / Sign in** → a small in‑app window opens claude.ai login
- **ChatGPT / Codex**: **ChatGPT sign‑in** → small window ("Continue with Google" etc. supported)
- **Gemini**: **Gemini sign‑in** → small window for Google login

All logins happen in a **small in‑app window**; on success the window closes automatically and usage appears. Log out / switch accounts from **Settings…**.

> **Tip**: Settings lets you pick the **auto‑refresh interval** (2 / 5 / 15 / 30 / 60 min). For the reason in the warning above, **15 min or more is recommended**.

---

## Privacy & security

- TokenCounter has **no backend server.** It talks **directly** to each provider and sends nothing to any third party.
- Logins use each provider's official auth page, shown in a **small in‑app window (WebKit)**. It does not read your system browser's cookies or profile.
- On success it stores the access/refresh token, account ID, expiry, and email in the app's **UserDefaults**.
  **⚠️ UserDefaults is not encrypted storage.** It can be read by programs running as the same macOS user, or from a preferences backup. (Not using the Keychain is a choice to avoid repeated password prompts, not a security improvement.)
- Token values, auth headers, and server response bodies are never written to logs.

---

## Troubleshooting

- **Only one service shows `N/A`**: you haven't signed into it, or that account has no such usage window. Signing into one service is enough; the others showing `N/A` is fine.
- **`⚠` shown**: login is required or the last lookup failed. Try **Sign in again** or **Refresh now** for that icon.
- **A value looks wrong**: it's shown exactly as the server returns it. 100% used means "0% remaining", which is normal.

---

## For developers

```sh
swift build
swift test
swift run TokenCounter
```

- No external runtime dependencies (pure Swift / SwiftUI / AppKit / WebKit).
- Each provider has an independent browser‑OAuth implementation; there is no CLI/file/Keychain fallback.

---

## Disclaimer

TokenCounter is **not** an official product of Anthropic, OpenAI, or Google, and does not imply any affiliation, endorsement, or certification. "Claude", "ChatGPT", "Codex", "Gemini", and their logos are trademarks of their respective owners. Names and icons here are used solely to **identify which service** each item refers to.

## License

[MIT](LICENSE)
