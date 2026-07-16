# Contributing to homelab-scripts

[code-of-conduct]: CODE_OF_CONDUCT.md
[security-policy]: SECURITY.md
[license]: https://github.com/Racerx323/homelab-scripts/blob/main/LICENSE.md
[new-issue]: https://github.com/Racerx323/homelab-scripts/issues/new/choose
[pull-requests]: https://github.com/Racerx323/homelab-scripts/pulls

Thank you for considering a contribution to `homelab-scripts`. Contributions
that improve the scripts, registry files, Task Scheduler templates, validation,
or documentation are welcome.

This project is maintained in spare time. Please keep reports and pull requests
focused, reproducible, and respectful. All contributors must follow the
[Contributor Code of Conduct][code-of-conduct].

## Ways to Contribute

- Report a reproducible bug through the [issue forms][new-issue].
- Propose a new utility or improvement before implementing a large change.
- Correct or expand documentation and rollback instructions.
- Improve portability, validation, or safety checks.
- Submit a focused [pull request][pull-requests].

Do not open a public issue for a suspected vulnerability. Follow the
[Security Policy][security-policy] instead.

## Development Setup

1. Fork and clone the repository:

   ```bash
   git clone https://github.com/YOUR_USERNAME/homelab-scripts.git
   cd homelab-scripts
   ```

2. Create a branch from `main`:

   ```bash
   git switch -c descriptive-branch-name
   ```

3. Install `pre-commit` and the system tools required by the hooks you plan to
   run. The configured checks use `markdownlint-cli2`, `yamllint`,
   `check-jsonschema`, `shellcheck`, `shfmt`, `jq`, and `gitleaks`.

4. Run the repository checks:

   ```bash
   pre-commit run --all-files
   ```

## Contribution Guidelines

### General

- Keep each change scoped to one utility or concern.
- Preserve safe defaults and document elevated operations.
- Never commit credentials, private endpoints, account SIDs, or machine-specific
  usernames. Use explicit placeholders in reusable examples.
- Update the relevant README whenever behavior, prerequisites, installation, or
  rollback steps change.

### Registry Files

- Document every key and value the file adds, changes, or deletes.
- Provide or document a rollback path.
- Remember that `.reg` DWORD data is hexadecimal.
- Test both installation and removal on a supported Windows test system.

### PowerShell and Task Scheduler

- Avoid hard-coded user paths, SIDs, hostnames, and service endpoints.
- Use parameters or clearly documented placeholders for local values.
- Keep exported Task Scheduler XML portable and document required substitutions.
- Validate PowerShell syntax and imported task behavior on Windows.

### Documentation

- Use Markdown and keep commands directly runnable unless marked as templates.
- Explain prerequisites, expected results, verification, and rollback.
- Run `markdownlint-cli2` before submitting documentation changes.

## Reporting Bugs

Search existing issues before filing a report. Include the affected utility,
operating-system version, relevant PowerShell or WSL version, exact reproduction
steps, expected and actual behavior, and sanitized logs or screenshots.

## Pull Requests

Before opening a pull request:

- Review your own diff for machine-specific or sensitive data.
- Run all applicable automated checks.
- Add or update tests for every behavior change, including relevant edge cases.
- Preserve backward compatibility, or document compatibility impact, migration,
  and rollback steps when a breaking change is unavoidable.
- Test Windows-specific behavior on Windows when possible.
- Add or update documentation.
- Use the `[homelab-scripts] <Title>` pull-request title format.
- Link related issues or pull requests.
- Confirm the change is well-tested and documentation is updated where
  applicable.
- Obtain at least one peer review before merging.
- Keep commits and the pull-request description clear and focused.

Large changes should start with an issue so the design and scope can be agreed
before implementation.

## License

This project is licensed under GPL-3.0. By contributing, you agree that your
contributions will be licensed under the same terms. See [LICENSE][license].
