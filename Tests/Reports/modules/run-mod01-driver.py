#!/usr/bin/env python3
"""Small MOD-01 driver; no app build, models or owner's preferences.

Compile the actual pure policy and exact production module declarations/readers,
with only Settings' unrelated dependencies removed and its defaults injected.
This is focused contract evidence, not full app/navigation integration.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / "Sources/NextNotes"


def declaration(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


settings = (SOURCE / "Support/Settings.swift").read_text()
properties = [declaration(settings, "var " + name + ": Bool") for name in
              ["moduleDictationEnabled", "moduleMeetingsEnabled", "agentEnabled"]]
# Mutation operates only on the compiler's temporary fixture, never the app source.
if "--omit-dictation-write" in sys.argv:
    properties[0] = properties[0].replace(
        "didSet { defaults.set(moduleDictationEnabled, forKey: Keys.moduleDictationEnabled) }", "didSet {}")
reader = declaration(settings, "nonisolated static func initialModuleEnabled")
convenience = declaration(settings, "func isModuleEnabled")
key_lines = []
init_lines = []
for property_name, module in [("moduleDictationEnabled", "dictation"),
                              ("moduleMeetingsEnabled", "meetings"),
                              ("agentEnabled", "assistant")]:
    key_lines.append(re.search(r'        static let ' + property_name + r' = "[^"]+"', settings)[0])
    line = property_name + " = Self.initialModuleEnabled(." + module + ", from: defaults)"
    assert line in settings, "actual Settings.init must call the tested producer: " + line
    init_lines.append(line)

navigation = (SOURCE / "Support/NavigationState.swift").read_text()
onboarding = (SOURCE / "UI/Onboarding/OnboardingFlow.swift").read_text()
types = "import Foundation\n" + declaration(navigation, "enum SidebarSection") + "\n"
types += declaration(onboarding, "enum OnboardingStep") + "\n"
types += "@MainActor final class Settings {\nprivate let defaults: UserDefaults\n"
types += "\n".join(properties + [reader, convenience])
types += "\nprivate enum Keys {\n" + "\n".join(key_lines) + "\n}\n"
types += "init(defaults: UserDefaults) { self.defaults = defaults\n" + "\n".join(init_lines) + "\n}\n}\n"

with tempfile.TemporaryDirectory(prefix="nextnotes-mod01-") as directory:
    folder = pathlib.Path(directory)
    reduced_types = folder / "ProductionModuleDeclarations.swift"
    reduced_types.write_text(types)
    executable = folder / "mod01-driver"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(reduced_types), str(SOURCE / "Support/ModulePolicy.swift"),
                    str(ROOT / "Tests/Reports/modules/mod01-driver.swift"),
                    "-o", str(executable)], check=True)
    sys.exit(subprocess.run([str(executable)]).returncode)
