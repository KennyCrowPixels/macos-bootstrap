# macOS Offline Admin Bootstrapper

A single POSIX `bash` script (`bootstrap.sh`) that you run from the **macOS
Recovery OS Terminal** on an Apple Silicon Mac (M1 / M1 Max, macOS Sonoma or
Sequoia). It:

1. Finds your mounted, writable **Data** volume.
2. Prompts for a `username`, `full_name`, and `password` (defaults: `admin` / `Administrator` / `password`).
3. Creates a full **local administrator** account directly in the on-disk
   directory database using `dscl -f ... localonly`:
   - `UniqueID 501`, `PrimaryGroupID 20`, `UserShell /bin/zsh`,
     `RealName`, and `NFSHomeDirectory /Users/<username>`.
   - Sets the password with `dscl ... -passwd`.
   - Adds the user to the `admin` group (`GroupMembership` + `GroupMembers`).
   - Creates `/Users/<username>` on the Data volume, owned by `501:20`.
4. Touches `.AppleSetupDone` and `.AppleDiagnosticsSetupDone` so the **Setup
   Assistant is skipped** on the next boot.
5. Adds `0.0.0.0` sinkhole entries to `/etc/hosts` for the Apple device
   enrollment / MDM hosts.

> ⚠️ **Use only on hardware you own or are authorized to administer.** This
> tool modifies the system directory database and can bypass Setup Assistant
> and DEP/MDM enrollment checks. Do not use it to circumvent management on
> devices you do not control.

---

## Prerequisites

- An Apple Silicon Mac (M1 / M1 Max) running macOS Sonoma (14) or Sequoia (15).
- Access to the device's internal disk (not FileVault-locked, or you know the
  unlock password / recovery key).
- A Wi-Fi network for the one-line `curl` install.

---

## Step-by-step

### 1. Boot into Recovery Mode (Apple Silicon)

1. **Shut the Mac down completely** (Apple menu → Shut Down).
2. Press and **hold the power button** until you see
   *"Loading startup options…"*.
3. Click **Options**, then **Continue**.
4. If prompted, select your admin user and enter the password (or unlock the
   disk with your FileVault recovery key).

### 2. Connect to Wi-Fi

In the top-right corner of the Recovery menu bar, click the **Wi-Fi icon** and
join your network. (You need internet for the `curl` one-liner.)

### 3. (If needed) Mount / unlock the Data volume

1. From the top menu bar choose **Utilities → Disk Utility**.
2. In the sidebar, select **Macintosh HD - Data** and click **Mount**
   (enter the FileVault password if asked).
3. Quit Disk Utility.

### 4. Open the Terminal

From the top menu bar choose **Utilities → Terminal**.

### 5. Run the bootstrapper (one line)

```sh
curl -sL <RAW-URL> | bash
```

Replace `<RAW-URL>` with your raw GitHub / Gist URL (see
[Publishing](#publishing-so-you-get-a-short-raw-url) below). Follow the
prompts: enter a username, full name, and password (or just press **Enter**
three times to accept the defaults).

> Tip: if typing a long URL is painful, use a URL shortener or a Gist whose
> raw URL you can shorten. See below.

### 6. Reboot

```sh
reboot
```

When the Mac restarts it will **skip Setup Assistant** and show the normal
login window. Sign in with the account you just created.

---

## Publishing (so you get a short raw URL)

### Option A — public GitHub repository

```sh
# from this folder
git init
git add bootstrap.sh README.md
git commit -m "Add macOS offline admin bootstrapper"
gh repo create macos-bootstrap --public --source=. --push
```

Raw URL will look like:

```
https://raw.githubusercontent.com/<you>/macos-bootstrap/main/bootstrap.sh
```

### Option B — public Gist (often shorter)

```sh
gh gist create --public bootstrap.sh
```

Then open the Gist, click **Raw**, and copy that URL. You can shorten it with
any URL shortener so it is easy to type into the Recovery Terminal.

---

## Troubleshooting

- **"Data volume is not writable"** – mount **Macintosh HD - Data** read/write
  in Disk Utility first, and make sure FileVault is unlocked.
- **"Not a valid macOS Data volume"** – the script looks for
  `.../private/var/db/dslocal/nodes/Default`. If your volume has a custom
  name, the script will list mounted volumes and let you type the path.
- **Login loop / password rejected** – reboot back into Recovery and re-run;
  the script updates the record in place if it already exists.
- **Undo the hosts sinkholes later** – from a normal admin session, edit
  `/etc/hosts` and remove the four `0.0.0.0 ...apple.com` lines.

---

## What gets changed (quick reference)

| Area | Path |
| --- | --- |
| Directory DB node | `<Data>/private/var/db/dslocal/nodes/Default` |
| New user record | `/Local/Default/Users/<username>` |
| Admin group | `/Local/Default/Groups/admin` |
| Home directory | `<Data>/Users/<username>` (owner `501:20`) |
| Skip Setup | `<Data>/private/var/db/.AppleSetupDone`, `.AppleDiagnosticsSetupDone` |
| Hosts sinkhole | `<Data>/private/etc/hosts` |
