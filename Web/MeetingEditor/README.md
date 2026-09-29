# Meeting notes editor

This is the local rich editor shown in the meeting window. Its compiled JavaScript is
checked in at `Resources/MeetingEditor/editor.js` so `make app` builds offline.

After changing `src/editor.js`, run `npm ci` and `npm run build` from this directory,
then commit the source, lockfile, and generated bundle together. `make app` copies the
HTML, CSS, JavaScript, and third-party licence texts into the signed app.

The Swift bridge stores the editor's HTML alongside Markdown in the existing meeting
scratchpad. Markdown remains the input to `notes.md` and meeting summaries.
