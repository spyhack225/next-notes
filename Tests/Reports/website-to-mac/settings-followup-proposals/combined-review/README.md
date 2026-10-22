# Combined Settings follow-up review

Off-source only. `responsive-and-native-actions.patch` merges the [responsive layout candidate](../responsive/README.md) and [two native text-action candidates](../native-actions/README.md) against three current frozen view files. Exact base/proposed hashes and patch identity are in `manifest.json`; baseline/proposed copies are retained here. Applicability was checked in baseline copies, and production Sources were unchanged.

The Formatting overlap is resolved concretely: its responsive helper owns the existing Reveal action, then its label becomes underlined native Text with DS ink and plain Button styling. The original current-source link patch and this merged patch are alternatives, not sequential patches. Do not apply both.

No profile List/row/height/selection/scroll changes, producer-input changes, model pass, capture lifecycle change, wrapper/style type, timer or permission gate is included. Agent's native text action is the third file. A separate SettingsSheet layout observation candidate is not part of this patch.

This is a reviewable proposal, not a fix verdict. The same app29 actual fixture cases must demonstrate original clipping/blue labels and corrected output; native button focus, activation, VoiceOver and busy-candidate clock admission remain explicit gates. Root must release exact Source/build/native ownership before any application or verification. The current native/build slot remains with runtime builds30/31.
