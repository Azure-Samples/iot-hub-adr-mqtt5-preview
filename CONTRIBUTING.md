# Contributing

This project welcomes contributions and suggestions. Most contributions require
you to agree to a Contributor License Agreement (CLA) declaring that you have
the right to, and actually do, grant us the rights to use your contribution.
For details, visit <https://cla.opensource.microsoft.com>.

When you submit a pull request, a CLA bot will automatically determine whether
you need to provide a CLA and decorate the PR appropriately (for example, a
status check or comment). Simply follow the instructions provided by the bot.
You will only need to do this once across all repos using our CLA.
Contributions are subject to Microsoft's CLA requirements.

## Proposing a change

1. Check existing issues and pull requests before starting work. Discuss larger
   changes in an issue before implementing them.
2. Create a branch or fork and make a focused change. Follow the existing C,
   C#, PowerShell, and documentation conventions.
3. Keep the Microsoft copyright and MIT license header in each source file.
   Preserve third-party notices and identify any copied or adapted code and its
   license in your pull request.
4. Run the relevant [offline validation](README.md#offline-validation).
   Include the commands, tool versions, and results in your pull request.
   Distinguish offline checks from live Azure validation.
5. Submit a pull request and address review comments. Do not commit credentials,
   environment manifests, private run directories, dependency source trees, or
   compiled binaries.

Live tests require your own authorized Azure subscription and can incur charges.
Never deploy to shared resources without permission. Follow the
[setup and cleanup guidance](README.md) and sanitize any logs you share.

Report non-security bugs through GitHub issues with the language, scenario,
tool versions, and a minimal reproduction. Report security vulnerabilities
privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## Code of conduct

This project has adopted the
[Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information, see the
[Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/)
or contact [opencode@microsoft.com](mailto:opencode@microsoft.com)
with any additional questions or comments.
