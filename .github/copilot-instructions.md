When using terminal tools in this workspace, use exactly one shared terminal.

- Reuse the same terminal session for all commands whenever possible.
- Do not start multiple terminals in parallel.
- Do not create background terminals or extra terminal sessions unless the user explicitly asks for that behavior.
- Prefer sequential commands in the shared terminal over parallel terminal work.
-  The best way to to this is to not run background processes in the terminal, and to not use the terminal for long-running processes that would prevent other commands from being run in the same terminal. If a long-running process is needed, ask the user to run it manually.