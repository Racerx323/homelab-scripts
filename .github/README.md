# Homelab Scripts

![License](https://badgen.net/github/license/Racerx323/homelab-scripts)
![Last commit](https://badgen.net/github/last-commit/Racerx323/homelab-scripts)
[![Open issues](https://badgen.net/github/open-issues/Racerx323/homelab-scripts)](https://github.com/Racerx323/homelab-scripts/issues?q=is%3Aissue%20state%3Aopen)
[![Pull requests](https://badgen.net/github/prs/Racerx323/homelab-scripts)](https://github.com/Racerx323/homelab-scripts/pulls)
<!-- markdownlint-disable MD013 MD033 -->
<a href="https://app.thecoderegistry.com/verify/vault/a2422c12-1834-467f-a0b9-d84adb876603" target="_blank" rel="noopener noreferrer">
  <img src="https://thecoderegistryprod.blob.core.windows.net/public-web/verification-badges/level-1/vault/a2422c12-1834-467f-a0b9-d84adb876603/default-style_1-2ff3a6964bbc.png?v=1784225721" alt="The Code Registry Verification Badge" width="100" />
</a>
<!-- markdownlint-enable MD013 MD033 -->

General-purpose administration and automation utilities for homelab systems
and workstations.

## 🏠 About the Project

This repository collects focused scripts, registry files, Task Scheduler
templates, and supporting documentation used to configure and maintain systems
in the homelab environment. Each utility is kept in its own directory with the
instructions and templates required to use or reverse the change.

The current utilities target Windows and WSL. Scripts may require elevated
permissions and should be reviewed before use on another system.

## 🧰 Included Utilities

- **[DNS Client cache settings](../windows/dns-cache/README.md):** Configures
  maximum positive and negative DNS cache lifetimes through the Windows
  registry.
- **[System Repair context menu](../windows/system-repair/README.md):** Adds a
  desktop context menu for SFC and DISM repair commands, with a matching
  uninstall registry file.
- **[WSL repository sync](../windows/wsl-code-directory-sync/README.md):**
  Provides portable Task Scheduler templates and a PowerShell notifier for
  syncing WSL repositories to Windows.

## 🗂️ Project Structure

```text
homelab-scripts/
├── .github/
│   ├── README.md
│   ├── CODE_OF_CONDUCT.md
│   ├── CONTRIBUTING.md
│   ├── SECURITY.md
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── ISSUE_TEMPLATE/
│   │   └── config.yml
│   └── workflows/
│       └── windows-powershell-tests.yml
├── windows/
│   ├── dns-cache/
│   │   ├── DNS_Cache_Settings.reg
│   │   └── README.md
│   ├── system-repair/
│   │   ├── install-system-repair-menu.reg
│   │   ├── uninstall-system-repair-menu.reg
│   │   ├── tests/
│   │   │   ├── README.md
│   │   │   └── SystemRepairMenu.Tests.ps1
│   │   └── README.md
│   └── wsl-code-directory-sync/
│       ├── README.md
│       ├── WSL GitHub Repo Sync.template.xml
│       ├── WSL2.reposync.apprise.notification.template.xml
│       ├── github_reposync_apprise_notify.ps1
│       └── tests/
│           └── GithubRepoSyncNotify.Tests.ps1
└── LICENSE.md
```

## 🚀 Usage

Open the README for the utility you want to use and review its prerequisites,
configuration placeholders, installation steps, and rollback instructions.
Do not import a registry file or Task Scheduler template until you understand
the changes it will make.

Windows registry files normally require administrator privileges. The WSL sync
templates must be customized with the local Windows account, SID, WSL username,
and Apprise endpoint before import.

## ✅ Validation

The repository uses local pre-commit hooks for applicable file types:

- `markdownlint-cli2` for Markdown
- `yamllint` and `check-jsonschema` for YAML and GitHub issue forms
- `shellcheck` and `shfmt` for shell scripts
- `jq` for JSON
- `gitleaks` for staged secret detection

Run all configured checks with:

```bash
pre-commit run --all-files
```

Windows-specific registry, PowerShell, and Task Scheduler behavior should also
be validated on a supported Windows test system before deployment.

## 💬 Support

Problems with scripts, templates, registry files, or documentation supplied by
this repository belong in the
[homelab-scripts issue tracker](https://github.com/Racerx323/homelab-scripts/issues/new/choose).

When reporting a problem, identify the affected utility and include the Windows
or WSL version, relevant commands, sanitized logs, and reproduction steps.

## 🔒 Security

Do not report security vulnerabilities through a public issue. Review the
[Security Policy](SECURITY.md) for supported versions and confidential
reporting instructions.

## 🤝 Contributing

Contributions to scripts, registry files, Task Scheduler templates, and
documentation are welcome. Review the
[contributing guidelines](CONTRIBUTING.md), then use an appropriate issue
template or open a focused pull request.

## 📄 License

This repository is licensed under the GNU General Public License v3.0. See
[LICENSE.md](../LICENSE.md).
