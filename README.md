# Script for Copying Files Using Prefixes

This script automates copying files from a remote path to a local directory, based on defined filename prefixes. It also archives any existing `.bak` files in the local path before copying.

---

## 📥 1. Clone the Repository

Open PowerShell and run:

```powershell
git clone https://github.com/IvanovvAlex/ScriptForFillesCopingUsingTheirPrefixes.git
```

Then navigate to the newly created folder by running:

```powershell
cd ScriptForFillesCopingUsingTheirPrefixes
```

---

## ⚙️ 2. Create `config.json`

Create a file named `config.json` in the same folder as the script with the following content:

```json
{
  "RemotePath": "",
  "Prefixes": [
    "",
    "",
    "",
    "",
    ""
  ],
  "LocalPath": "",
  "ArchivePath": ""
}
```

> 🔁 Modify the paths as needed for your environment.

---

## 🔐 3. Set Execution Policy (If Needed)

To allow script execution (if not already enabled):

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

> ✅ Accept the prompt if asked.

---

## ▶️ 4. Run the Script

Execute the script using:

```powershell
.\DownloadBackups.ps1
```

---

## ✅ What the Script Does

1. Loads the config from `config.json`
2. Checks connection to the remote path
3. Filters files by configured prefixes
4. Moves existing `.bak` files from the local path to the archive
5. Copies new files from the remote path to the local path
6. If something goes wrong, it rolls back all changes

---

## 🔁 Rollback Mechanism

In case of error:
- Newly copied files will be deleted
- Archived `.bak` files will be restored

---

## 💬 Questions?

Open an issue in the GitHub repo or contact the author.s