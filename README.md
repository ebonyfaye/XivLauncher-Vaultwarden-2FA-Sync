# XIVLauncher Multi-Client Vaultwarden 2FA Wrapper

Automated One-Time Password (TOTP) injection and profile synchronization wrapper for running multiple **Final Fantasy XIV** clients simultaneously via **XIVLauncher** and **ISBoxer**, backed by a self-hosted **Vaultwarden** (or official **Bitwarden**) vault.

> Built upon the original ISBoxer + XIVLauncher batch architecture ("Batch Voodoo") created by **[tsukasa](https://github.com/tsukasa)** ([`isboxer_ffxiv_batch`](https://github.com/tsukasa/isboxer_ffxiv_batch) / [`isboxer_ffxiv_guide`](https://github.com/tsukasa/isboxer_ffxiv_guide)).

---

## Features

- **Automated Multi-Client 2FA (Port `4646`):** Queries your unlocked Vaultwarden/Bitwarden vault via the Bitwarden CLI (`bw get totp`) and injects the 6-digit TOTP code directly into XIVLauncher's local HTTP listener.
- **Queue Serialization (`otp.lock`):** Prevents port `4646` collisions when launching multiple FFXIV clients at the same time in ISBoxer by queuing 2FA handshakes sequentially.
- **Mixed-Team Support (2FA + Non-2FA Accounts):** Characters with a Vaultwarden TOTP mapping auto-fill 2FA; characters without a mapping automatically skip the OTP check and launch normally.
- **Optional NAS Profile Sync (`ENABLE_NAS_SYNC`):** Toggleable `robocopy` mirror sync between a central network share (e.g., `X:\XIVLauncherBatch`) and a local staging folder (`C:\XIVLauncherBatch`) so Dalamud UI, plugins, and character configs stay synchronized across machines or profiles.
- **Clean Console Feedback:** Displays clear progress messages during vault lookup, OTP transmission, and acceptance without ever printing raw TOTP codes to the terminal.

---

## Repository Structure

```text
├── XIVLauncher.cmd              # Main launcher wrapper (handles NAS sync, otp.lock, and 2FA injection)
├── Update-VaultwardenMap.bat    # Syncs Vaultwarden vault and builds vw_items.txt + bw_session.txt
├── .gitignore                   # Prevents accidental commits of bw_session.txt and vw_items.txt
└── README.md
```

---

## Step 1: Install Required Tools (PowerShell & Bitwarden CLI)

### 1. Verify / Install PowerShell
Windows 10 and Windows 11 include **Windows PowerShell 5.1** out of the box, which works with these scripts. Optionally, you can install modern **PowerShell 7+** via `winget`:

1. Open **Command Prompt** (`cmd.exe`) or **Windows Terminal**.
2. Check if PowerShell is available:
   ```cmd
   powershell -Command "$PSVersionTable.PSVersion"
   ```
3. *(Optional)* Install the latest PowerShell 7:
   ```cmd
   winget install --id Microsoft.PowerShell --source winget
   ```

### 2. Install Bitwarden CLI (`bw.exe`)
You can install the Bitwarden CLI automatically using **winget** (recommended) or manually via ZIP download.

#### Option A: Install via `winget` (Recommended)
1. Open **Command Prompt** or **PowerShell** and run:
   ```cmd
   winget install --id Bitwarden.CLI --source winget
   ```
2. **Close and reopen** your terminal window so Windows refreshes your `PATH`.
3. Verify the installation:
   ```cmd
   bw --version
   ```

#### Option B: Manual Download
1. Download the Windows ZIP (`bw-windows-xxxx.zip`) from the [Bitwarden CLI Releases](https://github.com/bitwarden/clients/releases) page.
2. Extract `bw.exe` into a permanent folder (for example, `C:\Tools\BitwardenCLI\` or directly inside your `C:\XIVLauncherBatch\` folder).
3. Add that folder to your Windows **System Environment Variables -> Path** (or place `bw.exe` in the same directory as `XIVLauncher.cmd` and `Update-VaultwardenMap.bat`).

### 3. Connect Bitwarden CLI to Vaultwarden (or Official Bitwarden)
1. If you use a **self-hosted Vaultwarden** server, set your server URL first *(skip this line if you use official `bitwarden.com`)*:
   ```cmd
   bw config server https://vault.yourdomain.com
   ```
2. Log in to your vault once in the terminal:
   ```cmd
   bw login
   ```
   *(Enter your email address, master password, and 2FA code if prompted.)*

### 4. Create the Local Session Directory & Generate `bw_session.txt`
   Even when running shared launcher configs from a NAS/network drive, each PC requires its own local Bitwarden CLI session token stored in `C:\XIVLauncherBatch\bw_session.txt`. Run the following in PowerShell:
   ```powershell
   New-Item -ItemType Directory -Force -Path "C:\XIVLauncherBatch" | Out-Null
   $session = bw unlock --raw
   if ($session) {
       [System.IO.File]::WriteAllText("C:\XIVLauncherBatch\bw_session.txt", $session)
   }```


---

## Step 2: Configure Your Vaultwarden Folder & 2FA Keys

1. Log in to your **Vaultwarden** (or Bitwarden) web vault.
2. Create a folder named **`FFIV`** (exact spelling, or update the folder name in `Update-VaultwardenMap.bat`).
3. Inside the `FFIV` folder, create a **Login** item for each FFXIV account/character that uses 2FA:
   - **Name:** Must match the character folder name passed to the wrapper (e.g., `blossom`, `bubbles`).
   - **Username / Password:** Your Square Enix ID and password.
   - **Authenticator Key (TOTP):** Paste the setup key provided by Square Enix Account Management when enabling Software Authenticator 2FA.

---

## Step 3: Configure the Scripts

### 1. Edit `XIVLauncher.cmd`
Open `XIVLauncher.cmd` in a text editor and verify the paths and toggle at the top:

```bat
set "XIVLAUNCHER_LOCALDATA=%LOCALAPPDATA%\XIVLauncher"
set "ROAMINGPATH_ROOT=X:\XIVLauncherBatch"
set "LOCAL_ROAMING_ROOT=C:\XIVLauncherBatch"
set "ENABLE_NAS_SYNC=true"
```

- **`ENABLE_NAS_SYNC=true`**: Mirrors character profiles from your network share (`X:\XIVLauncherBatch`) to local disk (`C:\XIVLauncherBatch`) before launch, and syncs updated Dalamud/UI configs back on exit.
- **`ENABLE_NAS_SYNC=false`**: Runs purely from local storage without requiring a network drive.

### 2. Generate `vw_items.txt` and `bw_session.txt`
1. Run **`Update-VaultwardenMap.bat`** and enter your Vaultwarden master password when prompted.
2. The script will unlock your vault, sync the latest items, filter your `FFIV` folder, and generate two files in your root batch directory:
   - `bw_session.txt` (your active CLI session token)
   - `vw_items.txt` (maps character names to Vaultwarden item IDs):
     ```text
     blossom=11111111-2222-3333-4444-555555555555
     bubbles=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
     ```
3. Re-run **`Update-VaultwardenMap.bat`** whenever you add a new character or rotate a 2FA secret.

> **Security Warning:** Never upload `bw_session.txt` or `vw_items.txt` to GitHub. Keep both listed in `.gitignore`.

---

## Step 4: Configure XIVLauncher & ISBoxer

### 1. XIVLauncher Settings (Per Character)
1. Launch XIVLauncher once per character profile to log in and save your Square Enix password.
2. On the XIVLauncher login screen:
   - Check **Use One-Time Password** (for accounts with 2FA enabled).
   - Check **Log in automatically** (optional, once password is saved).
3. In XIVLauncher **Settings -> Auto-Login / Web Services**:
   - Ensure **Enable XL Web Services** is enabled (listens locally on `http://localhost:4646/ffxivlauncher/<OTP>`).

### 2. ISBoxer Virtual Files (`XIVLauncher-env.cmd`)
Following [tsukasa's ISBoxer FFXIV Guide](https://github.com/tsukasa/isboxer_ffxiv_guide):
1. Point your Inner Space FFXIV game profile executable to **`XIVLauncher.cmd`**.
2. Assign a per-character **`XIVLauncher-env.cmd`** virtual file in ISBoxer so each character sets its own profile folder name before `XIVLauncher.cmd` runs.

---

## How It Works

```text
[ISBoxer / Launcher]
        │
        ▼
[1. NAS Sync (Optional)] ──► robocopy X:\XIVLauncherBatch\<char> -> C:\XIVLauncherBatch\<char>
        │
        ▼
[2. Lookup vw_items.txt]
        ├── No mapping found ──► Prints skip notice & launches XIVLauncher directly
        │
        └── Mapping found ─────► Acquires otp.lock (queues parallel launches)
                                   │
                                   ▼
                                 Launches XIVLauncher.exe (listens on port 4646)
                                   │
                                   ▼
                                 Runs `bw get totp <item_id> --nointeraction`
                                   │
                                   ▼
                                 Sends HTTP GET to localhost:4646/ffxivlauncher/<OTP>
                                   │
                                   ▼
                                 Releases otp.lock for next client in queue
        │
        ▼
[3. Game Exit] ───────────► Syncs updated UI/plugin configs back to NAS (if enabled)
```

---

## Troubleshooting

- **`'bw' is not recognized as an internal or external command`**
  - Close and reopen Command Prompt after installing via `winget`, or verify `bw.exe` is in your system `PATH`.
- **`No Vaultwarden 2FA mapping found for <character> - skipping OTP...`**
  - Expected for characters that do not use 2FA.
  - If the character *does* use 2FA, make sure its item is inside the **`FFIV`** folder in Vaultwarden, has an Authenticator Key saved, and re-run `Update-VaultwardenMap.bat`.
- **Vaultwarden session expired / `bw get totp` fails:**
  - Run `Update-VaultwardenMap.bat` again to refresh `bw_session.txt`.
- **Wrong password error after changing your Square Enix password:**
  - Untick **Log in automatically** in XIVLauncher for that character once, enter the new password, and let XIVLauncher update Windows Credential Manager.
- **Port `4646` timeout:**
  - Confirm **Use One-Time Password** is checked on that character's XIVLauncher window and no other program is using TCP port `4646`.

---

## Credits & Acknowledgments

- **[tsukasa](https://github.com/tsukasa)** — Original creator of [`isboxer_ffxiv_batch`](https://github.com/tsukasa/isboxer_ffxiv_batch) and [`isboxer_ffxiv_guide`](https://github.com/tsukasa/isboxer_ffxiv_guide), which established the ISBoxer + XIVLauncher batch launcher and per-character virtual file (`XIVLauncher-env.cmd`) architecture.
- **[goatcorp / XIVLauncher](https://github.com/goatcorp/FFXIVQuickLauncher)** — For XIVLauncher and its local HTTP OTP endpoint (`localhost:4646`).
- **[Vaultwarden](https://github.com/dani-garcia/vaultwarden)** & **[Bitwarden CLI](https://github.com/bitwarden/clients)** — For self-hosted vault and TOTP automation support.
- **[Lavish Software / ISBoxer](https://isboxer.com/)** — For Inner Space and ISBoxer multi-boxing virtual file support.