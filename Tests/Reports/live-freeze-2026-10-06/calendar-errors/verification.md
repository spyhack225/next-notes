# Google calendar error producers

Calendar reads previously swallowed every selected-calendar failure and returned an empty result; CalendarService then displayed the provider as connected. The provider now preserves partial successes and successful empty calendars but throws the original first error when every selected read fails, so the existing refresh consumer exposes the failure.

OAuth decoding previously discarded the machine error code and the token producer cleared the stored connection on every HTTP400. It now retains the code separately and clears only a verified HTTP400 invalid_grant. Unrelated400, unknown400 and500 failures retain the connection. Normal account storage/choice/auth flows are otherwise unchanged.

Same seven real OAuth→provider→CalendarService.refresh scenarios: original `0b8806a31180` failed10 assertions; fixed `a43709f40a47` passes. Isolated HTTP/token callbacks exercise real decoding and error consumption without network, Keychain or owner events. Cases include revoked/other/unknown/server token errors, every-calendar failure, partial success with exact event identity, and genuine empty calendars. Related fake calendar, schedule and meeting reconciliation flags are run once before installation. All owned launcher/fixture temps are removed. Raw artifacts: `~/Library/Caches/NextNotesBuild/integration/calendar-provider-errors/{original,fixed}/`.

The retained owner incident errors lacked status/code. These confirmed producer defects do not establish the original Google failure's cause or broader freeze resolution. Native microphone/system tap and standalone speech/model controls passed separately; the full combined meeting memory spike remains open.
