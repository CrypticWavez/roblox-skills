"""Read-only health check of the owner's PC setup (docs/pc-setup.md). Prints a report; writes nothing.

  python3 tools/pc_doctor.py                       every check, text report
  python3 tools/pc_doctor.py --json                the same as JSON on stdout (never commit it)
  python3 tools/pc_doctor.py --blender <exe> --tools-dir <dir> --claude-skills <dir> --codex-skills <dir>

Checks (docs/pc-setup.md has one section per item):
  toolchain       rojo, lune, stylua, selene, luau-lsp at the versions in rokit.toml
  pc-tools        darklua and wally at templates/pc-tools/rokit.toml (game-repo tools)
  tools-folder    --tools-dir holds a rokit.toml equal to templates/pc-tools/rokit.toml, outside git
  path-order      Rokit's bin folder comes before Aftman's on PATH, and `rojo` resolves to Rokit
  node            Node.js 20 or newer (the hooks need it)
  telemetry       DISABLE_TELEMETRY is on for the blender server in .mcp.json and .codex/config.toml;
                  with --blender, the MCP add-on's telemetry preferences read through Blender (read-only)
  skills-copy     the user skill folders hold current copies of the starter's skills (tools/user_skills.py)
  imagemagick, krita, audacity, gltf-transform, material-maker   owner-approved installs
  inkscape, vscode-extensions, blender-lab                          optional extras
Statuses: PASS, FAIL (wrong version, wrong PATH order, telemetry on, Node too old), TODO (an approved item
not installed yet), OPTIONAL (an extra not installed), UNCHECKED (needs an argument). Exit 1 when any check
FAILs, else 0. Your home folder is shown as ~; nothing is written anywhere.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
TOOLCHAIN = ROOT / "rokit.toml"
PC_TOOLS = ROOT / "templates" / "pc-tools" / "rokit.toml"
VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")
VSCODE_EXTENSIONS = ["JohnnyMorganz.luau-lsp", "JohnnyMorganz.stylua", "Kampfkarren.selene-vscode", "anthropic.claude-code", "openai.chatgpt"]
TRUE = {"1", "true", "yes", "on"}
# Read-only: lists telemetry/consent preferences of enabled MCP add-ons; never saves preferences.
BLENDER_SCRIPT = r"""
import json, bpy
found = {}
for addon in bpy.context.preferences.addons:
    if "mcp" not in addon.module.lower():
        continue
    prefs = getattr(addon, "preferences", None)
    if prefs is None:
        continue
    for prop in prefs.bl_rna.properties:
        name = prop.identifier
        if "telemetry" in name.lower() or "consent" in name.lower():
            found[addon.module + "." + name] = getattr(prefs, name, None)
for prop in bpy.types.Scene.bl_rna.properties:
    name = prop.identifier
    if "mcp" in name.lower() and "telemetry" in name.lower():
        found["Scene." + name] = getattr(bpy.context.scene, name, None)
print("PC_DOCTOR_BLENDER " + json.dumps({"addons": [a.module for a in bpy.context.preferences.addons if "mcp" in a.module.lower()], "telemetry": found}, default=str))
"""


def pins(path):
    """{tool: version} from a rokit.toml [tools] table."""
    found = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        match = re.match(r'^\s*([A-Za-z0-9_-]+)\s*=\s*"[^"@]+@([^"]+)"', line)
        if match:
            found[match.group(1)] = match.group(2)
    return found


def version_of(text):
    match = VERSION.search(text or "")
    return ".".join(match.groups()) if match else None


class Doctor:
    def __init__(self, env=None, root=ROOT, timeout=60):
        self.env = dict(os.environ if env is None else env)
        self.root = Path(root)
        self.timeout = timeout
        self.results = []

    # ------------------------------------------------------------- helpers
    def which(self, name):
        return shutil.which(name, path=self.env.get("PATH", ""))

    def run(self, argv):
        """(exit code, stdout+stderr) or (None, reason) when it cannot run."""
        exe = self.which(argv[0]) if not os.path.isabs(argv[0]) else argv[0]
        if not exe:
            return None, "not found on PATH"
        try:
            proc = subprocess.run([exe, *argv[1:]], capture_output=True, text=True, timeout=self.timeout, env=self.env)
        except (OSError, subprocess.SubprocessError) as err:
            return None, f"could not run: {err.__class__.__name__}"
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")

    def add(self, check, status, detail, fix=None):
        row = {"check": check, "status": status, "detail": detail}
        if fix:
            row["fix"] = fix
        self.results.append(row)
        return row

    # ------------------------------------------------------------- checks
    def tool_versions(self, check, manifest, tools=None, missing_status="FAIL"):
        wanted = pins(manifest)
        for tool in tools or sorted(wanted):
            code, out = self.run([tool, "--version"])
            got = version_of(out) if code == 0 else None
            if code is None:
                self.add(f"{check}:{tool}", missing_status, f"{tool} {out}; pinned {wanted[tool]}", "rokit install (docs/pc-setup.md)")
            elif got != wanted[tool]:
                self.add(f"{check}:{tool}", "FAIL", f"{tool} reports {got or 'no version'} (exit {code}); pinned {wanted[tool]}", "rokit install, then check PATH order")
            else:
                self.add(f"{check}:{tool}", "PASS", f"{tool} {got}")

    def tools_folder(self, folder):
        if not folder:
            return self.add("tools-folder", "UNCHECKED", "pass --tools-dir <the folder holding the pc-tools rokit.toml>")
        path = Path(folder).expanduser()
        manifest = path / "rokit.toml"
        if not manifest.is_file():
            return self.add("tools-folder", "TODO", f"{self.show(path)} has no rokit.toml", "copy templates/pc-tools/rokit.toml there and run rokit install")
        if any((p / ".git").exists() for p in [path.resolve(), *path.resolve().parents]):
            return self.add("tools-folder", "FAIL", f"{self.show(path)} is inside a git repository", "use a plain folder outside any repository")
        if pins(manifest) != pins(PC_TOOLS):
            return self.add("tools-folder", "FAIL", f"{self.show(manifest)} pins {pins(manifest)}, the template pins {pins(PC_TOOLS)}", "copy the template again and run rokit install")
        return self.add("tools-folder", "PASS", f"{self.show(manifest)} matches templates/pc-tools/rokit.toml")

    def path_order(self):
        entries = [e for e in self.env.get("PATH", "").split(os.pathsep) if e]

        def index(marker):
            for i, entry in enumerate(entries):
                parts = [p.lower() for p in re.split(r"[\\/]+", entry)]
                if marker in parts:
                    return i
            return None

        rokit, aftman = index(".rokit"), index(".aftman")
        rojo = self.which("rojo")
        if rokit is None:
            return self.add("path-order", "TODO", "no .rokit/bin folder on PATH", "install Rokit (docs/pc-setup.md)")
        parts = [p.lower() for p in re.split(r"[\\/]+", rojo or "")]
        if aftman is not None and aftman < rokit:
            why = "; rojo resolves to Rokit for now, but any other Aftman shim would win" if ".rokit" in parts else ", so bare `rojo` runs Aftman's shim"
            return self.add("path-order", "FAIL", "Aftman's bin folder comes before Rokit's on PATH" + why, "move the .rokit/bin entry above .aftman/bin, or remove .aftman/bin from the system Path (Windows searches it before user entries) or uninstall Aftman, then open a new terminal")
        if rojo and ".rokit" not in parts:
            return self.add("path-order", "FAIL", f"rojo resolves to {self.show(rojo)}, not Rokit's shim", "put .rokit/bin first on PATH")
        return self.add("path-order", "PASS", "Rokit's bin folder is on PATH" + (" before Aftman's" if aftman is not None else "") + (", and rojo resolves to it" if rojo else ""))

    def node(self):
        code, out = self.run(["node", "--version"])
        got = version_of(out) if code == 0 else None
        if code is None or got is None:
            return self.add("node", "FAIL", f"node: {out.strip() if code is None else 'no version'}", "install Node.js 20 or newer (the hooks need it)")
        major = int(got.split(".")[0])
        return self.add("node", "PASS" if major >= 20 else "FAIL", f"node {got}", None if major >= 20 else "install Node.js 20 or newer")

    def telemetry(self, blender=None):
        problems, notes = [], []
        mcp = self.root / ".mcp.json"
        try:
            servers = json.loads(mcp.read_text(encoding="utf-8")).get("mcpServers", {})
            value = str(((servers.get("blender") or {}).get("env") or {}).get("DISABLE_TELEMETRY", "")).lower()
            (notes if value in TRUE else problems).append(f".mcp.json blender DISABLE_TELEMETRY={value or 'unset'}")
        except (OSError, ValueError) as err:
            problems.append(f".mcp.json unreadable ({err.__class__.__name__})")
        codex = self.root / ".codex" / "config.toml"
        if codex.is_file():
            text = codex.read_text(encoding="utf-8")
            block = re.search(r"^\[mcp_servers\.blender\]\s*$(.*?)(?=^\[)", text + "\n[", re.M | re.S)
            match = re.search(r'DISABLE_TELEMETRY\s*=\s*"?([A-Za-z0-9]+)"?', block.group(1)) if block else None
            value = match.group(1).lower() if match else ""
            (notes if value in TRUE else problems).append(f".codex/config.toml blender DISABLE_TELEMETRY={value or 'unset'}")
        if problems:
            self.add("telemetry:server", "FAIL", "; ".join(problems + notes), 'set env DISABLE_TELEMETRY = "true" for the blender server')
        else:
            self.add("telemetry:server", "PASS", "; ".join(notes))
        if not blender:
            return self.add("telemetry:addon", "UNCHECKED", "pass --blender <Blender executable> to read the MCP add-on's telemetry preference (read-only)", "or check Edit > Preferences > Add-ons by hand")
        code, out = self.run([blender, "-b", "--python-expr", BLENDER_SCRIPT])
        line = next((l for l in (out or "").splitlines() if l.startswith("PC_DOCTOR_BLENDER ")), None)
        if code is None or line is None:
            return self.add("telemetry:addon", "FAIL", f"could not read the add-on preferences ({out.strip()[-200:] if out else 'no output'})", "check Edit > Preferences > Add-ons by hand")
        data = json.loads(line[len("PC_DOCTOR_BLENDER "):])
        if not data["telemetry"]:
            return self.add("telemetry:addon", "TODO", f"no telemetry preference found (MCP add-ons enabled: {data['addons'] or 'none'})", "enable the MCP add-on, then rerun; or confirm by hand")
        on = sorted(k for k, v in data["telemetry"].items() if v is True or str(v).lower() in TRUE)
        if on:
            return self.add("telemetry:addon", "FAIL", f"telemetry is on: {', '.join(on)}", "untick it in the add-on preferences and Save Preferences")
        return self.add("telemetry:addon", "PASS", f"off: {', '.join(sorted(data['telemetry']))}")

    def skills(self, claude=None, codex=None):
        import user_skills  # noqa: E402

        home = Path(self.env.get("USERPROFILE") or self.env.get("HOME") or Path.home())
        targets = [("claude", claude or home / ".claude" / "skills", claude is not None), ("codex", codex or home / ".agents" / "skills", codex is not None)]
        for label, folder, explicit in targets:
            folder = Path(folder).expanduser()
            if not folder.is_dir():
                self.add(f"skills-copy:{label}", "TODO" if explicit else "UNCHECKED", f"{self.show(folder)} does not exist", f"python3 tools/user_skills.py --{label} {self.show(folder)} --apply")
                continue
            states = user_skills.status(folder)
            bad = [f"{n} {s}" for n, s in states if s != "current"]
            if bad:
                self.add(f"skills-copy:{label}", "TODO", f"{self.show(folder)}: {', '.join(bad)}", f"python3 tools/user_skills.py --{label} {self.show(folder)} --apply")
            else:
                self.add(f"skills-copy:{label}", "PASS", f"{self.show(folder)}: {len(states)} skills current")

    def app(self, check, names, version_args=None, windows=(), mac=(), approved=True, fix=None):
        """An installed program: on PATH (version when it has a CLI) or at a usual install location."""
        missing = "TODO" if approved else "OPTIONAL"
        for name in names:
            exe = self.which(name)
            if exe:
                if version_args is None:
                    return self.add(check, "PASS", f"{name} on PATH")
                code, out = self.run([exe, *version_args])
                got = version_of(out) if code == 0 else None
                return self.add(check, "PASS" if got else "FAIL", f"{name} {got or 'gave no version (exit ' + str(code) + ')'}")
        for base, rel in [(self.env.get("ProgramFiles"), w) for w in windows] + [("/", m) for m in mac]:
            if base and (Path(base) / rel).exists():
                return self.add(check, "PASS", f"found at {self.show(Path(base) / rel)}")
        return self.add(check, missing, f"not found ({' or '.join(names)} not on PATH)", fix)

    def vscode(self):
        code, out = self.run(["code", "--list-extensions", "--show-versions"])
        if code is None:
            return self.add("vscode-extensions", "OPTIONAL", "VS Code (`code`) not on PATH", "optional: install VS Code and the five extensions (docs/pc-setup.md)")
        have = {line.split("@")[0].lower(): line.split("@")[1] if "@" in line else "?" for line in out.split()}
        missing = [e for e in VSCODE_EXTENSIONS if e.lower() not in have]
        if missing:
            return self.add("vscode-extensions", "OPTIONAL", f"missing: {', '.join(missing)}", "code --install-extension <id> for each")
        return self.add("vscode-extensions", "PASS", ", ".join(f"{e}@{have[e.lower()]}" for e in VSCODE_EXTENSIONS))

    def blender_lab(self):
        try:
            servers = json.loads((self.root / ".mcp.json").read_text(encoding="utf-8")).get("mcpServers", {})
        except (OSError, ValueError):
            servers = {}
        if "blender_lab" in servers:
            return self.add("blender-lab", "PASS", "blender_lab server configured (trial)")
        return self.add("blender-lab", "OPTIONAL", "no blender_lab server configured (optional trial, docs/mcp.md)")

    def show(self, path):
        text = str(path)
        home = str(self.env.get("USERPROFILE") or self.env.get("HOME") or Path.home())
        return "~" + text[len(home):] if home not in ("", "/") and text.startswith(home) else text

    def all(self, args):
        self.tool_versions("toolchain", TOOLCHAIN)
        self.tool_versions("pc-tools", PC_TOOLS, ["darklua", "wally"], missing_status="TODO")
        self.tools_folder(args.tools_dir)
        self.path_order()
        self.node()
        self.telemetry(args.blender)
        self.skills(args.claude_skills, args.codex_skills)
        self.app("imagemagick", ["magick"], ["-version"], fix="install ImageMagick 7 (docs/pc-setup.md)")
        self.app("krita", ["krita"], None, windows=[r"Krita (x64)\bin\krita.exe"], mac=["Applications/krita.app"], fix="install Krita from krita.org")
        self.app("audacity", ["audacity"], None, windows=[r"Audacity\Audacity.exe"], mac=["Applications/Audacity.app"], fix="install Audacity from audacityteam.org")
        self.app("gltf-transform", ["gltf-transform"], ["--version"], fix="npm install --global @gltf-transform/cli@4.5.1, or use npx @gltf-transform/cli@4.5.1")
        self.app("material-maker", ["material_maker", "material-maker"], None, mac=["Applications/material_maker.app"], fix="unzip Material Maker into a tools folder and add it to PATH")
        self.app("inkscape", ["inkscape"], ["--version"], windows=[r"Inkscape\bin\inkscape.exe"], mac=["Applications/Inkscape.app"], approved=False, fix="optional: winget install Inkscape.Inkscape")
        self.vscode()
        self.blender_lab()
        return self.results


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true", help="print JSON instead of text")
    ap.add_argument("--blender", metavar="EXE", help="Blender executable, to read the MCP add-on telemetry preference")
    ap.add_argument("--tools-dir", metavar="DIR", help="the tools folder holding the pc-tools rokit.toml")
    ap.add_argument("--claude-skills", metavar="DIR", help="Claude Code user skill folder (default <home>/.claude/skills)")
    ap.add_argument("--codex-skills", metavar="DIR", help="Codex user skill folder (default <home>/.agents/skills)")
    args = ap.parse_args(argv)
    doctor = Doctor()
    results = doctor.all(args)
    counts = {}
    for row in results:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    if args.json:
        print(json.dumps({"schema": "pc-doctor/1", "counts": dict(sorted(counts.items())), "checks": results}, indent=2))
    else:
        for row in results:
            print(f"{row['status']:<10} {row['check']:<22} {row['detail']}" + (f"\n{'':<33}fix: {row['fix']}" if row.get("fix") and row["status"] != "PASS" else ""))
        print("pc_doctor: " + ", ".join(f"{n} {s}" for s, n in sorted(counts.items())) + " (nothing was written)")
    return 1 if counts.get("FAIL") else 0


if __name__ == "__main__":
    sys.exit(main())
