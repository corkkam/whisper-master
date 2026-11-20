# Contributing

Thanks for helping. Read [`AGENTS.md`](AGENTS.md) first: it holds the build gates
and the rules that protect users. Security bugs go through [`SECURITY.md`](SECURITY.md),
never a public issue.

## Workflow

1. Fork, then branch off `dev` as `feature/<short-name>` or `bug/<short-name>`.
2. Keep the change small and on one topic.
3. Before you open the PR, run:

   ```bash
   swift build
   swift test
   swift test --filter AudioReplayTests      # if you touched the transcription path
   bash eval/text-cleanup/run-eval.sh        # if you touched the cleanup path
   ```

4. Open the PR against `dev`. Say what changed, why, and how you tested it. Add a
   screenshot for a UI change (`WM_SNAPSHOT=<dir> .build/debug/WhisperMaster`).

## Rules

- Audio stays on the device. A change that sends audio off the Mac will not merge.
- Never commit a secret, key, token, certificate or `.env` file.
- Do not weaken the sign-in gate, the Sparkle signature check or any test.

## License

This project is licensed under the [GNU AGPL-3.0](LICENSE). By opening a pull
request you agree that your contribution is licensed under the same terms.
