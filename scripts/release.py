#!/usr/bin/env python3
"""Merges ready pull requests and publishes a release – interactive, on this Mac.

    scripts/release.py                 # go through open pull requests, then offer a release
    scripts/release.py --dry-run       # only show what would happen, change nothing
    scripts/release.py --verify v2.0.3 # check a published release (checksums, signature, version, codesign)

Pull requests: shows report, changes, CI status and warnings; merges only with green CI and exactly the
commit you looked at. Release: proposes the next version, checks the exact commit locally (optional),
tags it, waits for GitHub Actions and verifies the published files. Asks before every step that is
visible to others. See docs/bug-pipeline.md.

Needs: gh (logged in), git, Xcode, OpenCASCADE.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bugfix import WORK, checks, touched_protected  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
FIXES = re.compile(r"\b(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)\s+#(\d+)", re.I)
VERSION = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def run(cmd, cwd=ROOT, check=True, capture=True, timeout=None):
    r = subprocess.run(cmd, cwd=cwd, text=True, capture_output=capture, timeout=timeout)
    if check and r.returncode != 0:
        raise SystemExit(f"✗ {' '.join(cmd)}\n{(r.stderr or r.stdout or '')[-2000:]}")
    return r


def gh_json(*args):
    return json.loads(run(["gh", *args]).stdout or "null")


def log(msg=""):
    print(msg, flush=True)


def ask(question, choices=None, default=None):
    """choices: {key: label}; returns the key. Without choices: free text (default on Enter)."""
    while True:
        if choices:
            menu = "  ".join(f"[{k}] {v}" for k, v in choices.items())
            hint = f" (Enter = {default})" if default else ""
            answer = input(f"{question}\n  {menu}{hint}\n> ").strip().lower() or (default or "")
            if answer in choices:
                return answer
            log("  Bitte einen der Buchstaben in Klammern eingeben.")
        else:
            hint = f" [{default}]" if default else ""
            answer = input(f"{question}{hint}: ").strip()
            if answer or default is not None:
                return answer or default


def yes(question, default=True):
    return ask(question, {"j": "ja", "n": "nein"}, "j" if default else "n") == "j"


def confirm_public(what):
    """For steps everybody sees: type 'ja' in full."""
    return input(f"{what}\nDas ist öffentlich sichtbar. Zum Bestätigen „ja“ eintippen: ").strip().lower() == "ja"


# MARK: Pure helpers (tested in test_release.py)

def parse_version(tag):
    m = VERSION.match(tag or "")
    return tuple(int(x) for x in m.groups()) if m else None


def latest_version(tags):
    versions = sorted(v for v in map(parse_version, tags) if v)
    return versions[-1] if versions else (0, 0, 0)


def next_version(current, kind):
    major, minor, patch = current
    return {"patch": (major, minor, patch + 1), "minor": (major, minor + 1, 0), "major": (major + 1, 0, 0)}[kind]


def tag_name(v):
    return "v%d.%d.%d" % v


def linked_issues(*texts):
    return sorted({int(n) for t in texts for n in FIXES.findall(t or "")})


def ci_state(rollup):
    """'ok', 'läuft', 'fehlgeschlagen' or 'keine' from gh's statusCheckRollup."""
    if not rollup:
        return "keine"
    bad = {"FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}
    states = [(c.get("conclusion") or c.get("state") or "").upper() for c in rollup]
    if any(s in bad for s in states):
        return "fehlgeschlagen"
    if any(c.get("status", "COMPLETED").upper() != "COMPLETED" or s in ("", "PENDING", "EXPECTED")
           for c, s in zip(rollup, states)):
        return "läuft"
    return "ok"


def review_notes(pr, owner):
    """(blockers, warnings) for a pull request."""
    blockers, warnings = [], []
    if pr.get("isDraft"):
        blockers.append("Entwurf (Draft)")
    if pr.get("mergeable") == "CONFLICTING":
        blockers.append("Konflikt mit main – erst auflösen")
    state = ci_state(pr.get("statusCheckRollup"))
    if state == "fehlgeschlagen":
        blockers.append("CI ist rot")
    elif state == "läuft":
        warnings.append("CI läuft noch")
    elif state == "keine":
        warnings.append("keine CI-Ergebnisse")
    if pr.get("isCrossRepository"):
        warnings.append("kommt aus einem fremden Fork")
    if pr["author"]["login"].lower() != owner.lower():
        warnings.append(f"nicht von dir, sondern von @{pr['author']['login']}")
    protected = touched_protected([f["path"] for f in pr.get("files") or []])
    if protected:
        warnings.append("ändert geschützte Dateien: " + ", ".join(protected))
    return blockers, warnings


# MARK: Pull requests

PR_FIELDS = ("number,title,state,author,headRefName,headRefOid,isCrossRepository,isDraft,labels,body,url,"
             "statusCheckRollup,mergeable,files,additions,deletions")


def show_pr(pr, owner):
    labels = ", ".join(l["name"] for l in pr["labels"]) or "–"
    issues = linked_issues(pr["body"])
    log(f"\n━━ #{pr['number']} {pr['title']}")
    log(f"   {pr['url']}")
    log(f"   von @{pr['author']['login']} · Branch {pr['headRefName']} · Labels: {labels}")
    log(f"   behebt: {', '.join(f'#{n}' for n in issues) or '–'} · "
        f"{len(pr['files'] or [])} Dateien, +{pr['additions']} −{pr['deletions']} · CI: {ci_state(pr['statusCheckRollup'])}")
    blockers, warnings = review_notes(pr, owner)
    for b in blockers:
        log(f"   ⛔ {b}")
    for w in warnings:
        log(f"   ⚠️  {w}")
    return blockers, warnings


def try_out(pr):
    """Builds the app from exactly this pull request in its own working copy and opens it."""
    tree = WORK / f"review-{pr['number']}"
    log(f"   Baue die App mit dieser Korrektur in {tree} … (einige Minuten)")
    run(["git", "fetch", "-q", "origin", pr["headRefOid"]])
    if tree.exists():
        run(["git", "worktree", "remove", "--force", str(tree)], check=False)
    WORK.mkdir(parents=True, exist_ok=True)
    run(["git", "worktree", "add", "-q", "--detach", str(tree), pr["headRefOid"]])
    r = run(["scripts/build-app.sh", "debug"], cwd=tree, check=False, timeout=3600)
    if r.returncode != 0:
        log("   ✗ Bauen fehlgeschlagen:\n" + (r.stdout + r.stderr)[-1500:])
        return
    run(["open", "-n", str(tree / "build" / "6axis.app")])
    log("   ✓ Die Test-App ist offen (eigenes Fenster, neben deiner installierten). Ausprobieren, dann hier weiter.")


def merge(pr, repo, dry_run):
    subject = f"Merge #{pr['number']}: {pr['title']}"
    if dry_run:
        log(f"   (Probelauf) würde mergen: {subject}")
        return True
    # --match-head-commit: merges only the commit shown here – nothing pushed in between.
    r = run(["gh", "pr", "merge", str(pr["number"]), "--repo", repo, "--merge", "--delete-branch",
             "--match-head-commit", pr["headRefOid"], "--subject", subject], check=False)
    if r.returncode != 0:
        log("   ✗ Merge fehlgeschlagen: " + (r.stderr or r.stdout).strip()[-800:])
        return False
    shutil.rmtree(WORK / f"review-{pr['number']}", ignore_errors=True)
    run(["git", "worktree", "prune"], check=False)
    log("   ✓ gemergt – das Issue wird von GitHub geschlossen.")
    return True


def close(pr, repo, dry_run, reason=None):
    reason = reason or ask("   Kurze Begründung für das Issue (wird öffentlich kommentiert)", default="Die automatische Korrektur passt so nicht.")
    if dry_run:
        log("   (Probelauf) würde den Pull Request schließen")
        return
    run(["gh", "pr", "close", str(pr["number"]), "--repo", repo, "--delete-branch", "--comment", reason], check=False)
    for n in linked_issues(pr["body"]):
        run(["gh", "issue", "edit", str(n), "--repo", repo, "--remove-label", "fix-bereit", "--add-label", "braucht-mensch"], check=False)
        run(["gh", "issue", "comment", str(n), "--repo", repo, "--body", f"Korrektur #{pr['number']} verworfen: {reason}"], check=False)
    log("   ✓ geschlossen, Issue auf „braucht-mensch“ gesetzt.")


def wait_for_ci(pr, repo):
    log("   Warte auf die CI … (Strg-C bricht nur das Warten ab)")
    try:
        run(["gh", "pr", "checks", str(pr["number"]), "--repo", repo, "--watch", "--interval", "20"], check=False, capture=False)
    except KeyboardInterrupt:
        log()
    return gh_json("pr", "view", str(pr["number"]), "--repo", repo, "--json", PR_FIELDS)


def review_prs(repo, owner, dry_run):
    prs = gh_json("pr", "list", "--repo", repo, "--state", "open", "--limit", "50", "--json", PR_FIELDS)
    if not prs:
        log("Keine offenen Pull Requests.")
        return []
    # Fixes from scripts/bugfix.py first.
    prs.sort(key=lambda p: ("fix-bereit" not in {l["name"] for l in p["labels"]} and not p["headRefName"].startswith("fix/issue-"), p["number"]))
    log(f"{len(prs)} offene(r) Pull Request(s).")
    merged = []
    for pr in prs:
        # Fresh state: an earlier merge in this run can cause a conflict here.
        pr = gh_json("pr", "view", str(pr["number"]), "--repo", repo, "--json", PR_FIELDS)
        if pr["state"] != "OPEN":
            continue
        while True:
            blockers, warnings = show_pr(pr, owner)
            choices = {"b": "Bericht & Lösung lesen", "d": "Änderungen ansehen", "t": "App bauen & ausprobieren"}
            if ci_state(pr["statusCheckRollup"]) == "läuft":
                choices["w"] = "auf CI warten"
            if not blockers:
                choices["m"] = "mergen"
            choices.update({"x": "verwerfen", "s": "überspringen", "q": "fertig"})
            c = ask("Was tun?", choices, "s")
            if c == "b":
                log("\n" + (pr["body"] or "(kein Text)") + "\n")
                for n in linked_issues(pr["body"]):
                    issue = gh_json("issue", "view", str(n), "--repo", repo, "--json", "title,body,author")
                    log(f"── Issue #{n} von @{issue['author']['login']}: {issue['title']}\n{issue['body']}\n")
            elif c == "d":
                run(["gh", "pr", "diff", str(pr["number"]), "--repo", repo], check=False, capture=False)
            elif c == "t":
                try_out(pr)
            elif c == "w":
                pr = wait_for_ci(pr, repo)
            elif c == "m":
                ok = True
                if warnings:
                    ok = input("   Trotz der Hinweise oben mergen? Dann die PR-Nummer eintippen: ").strip() == str(pr["number"])
                if ok and merge(pr, repo, dry_run):
                    merged.append(pr)
                    break
            elif c == "x":
                close(pr, repo, dry_run)
                break
            elif c == "s":
                break
            elif c == "q":
                return merged
    return merged


# MARK: Release

def verify(tag, repo):
    """Downloads a published release and checks what the in-app updater relies on."""
    version = tag[1:]
    ok = True
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        r = run(["gh", "release", "download", tag, "--repo", repo, "--dir", str(d)], check=False)
        if r.returncode != 0:
            log("   ✗ Dateien nicht ladbar: " + r.stderr.strip())
            return False
        names = {p.name for p in d.iterdir()}
        for f in (f"6axis-{version}.dmg", f"6axis-{version}.zip", f"6axis-{version}.zip.sig", f"6axis-{version}.sha256"):
            if f not in names:
                log(f"   ✗ fehlt: {f}")
                ok = False
        if not ok:
            return False
        steps = [
            ("Prüfsummen", ["shasum", "-a", "256", "-c", f"6axis-{version}.sha256"], d),
            ("Update-Signatur", ["swift", str(ROOT / "scripts" / "update-key.swift"), "verify", str(d / f"6axis-{version}.zip")], ROOT),
            ("Entpacken", ["ditto", "-x", "-k", f"6axis-{version}.zip", "x"], d),
            ("Code-Signatur", ["codesign", "--verify", "--deep", "--strict", "x/6axis.app"], d),
        ]
        for name, cmd, cwd in steps:
            r = run(cmd, cwd=cwd, check=False)
            log(f"   {'✓' if r.returncode == 0 else '✗'} {name}")
            ok &= r.returncode == 0
        if ok:
            shown = run(["/usr/libexec/PlistBuddy", "-c", "Print CFBundleShortVersionString", "x/6axis.app/Contents/Info.plist"],
                        cwd=d, check=False).stdout.strip()
            log(f"   {'✓' if shown == version else '✗'} Version in der App: {shown}")
            ok &= shown == version
    latest = gh_json("api", f"repos/{repo}/releases/latest").get("tag_name")
    log(f"   {'✓' if latest == tag else '⚠️ '} neueste Version auf GitHub: {latest}")
    return ok


def wait_for_release(tag, repo):
    log("Warte auf GitHub Actions (Tests, Oberflächenprüfung, Bauen – meist 15–25 Minuten).")
    log(f"Strg-C beendet nur das Warten; prüfen später mit: scripts/release.py --verify {tag}")
    try:
        run_id, last = None, None
        for _ in range(240):
            runs = gh_json("run", "list", "--repo", repo, "--workflow", "release.yml", "--branch", tag,
                           "--json", "databaseId,status,conclusion,url", "--limit", "1")
            if runs:
                run_id = runs[0]
                state = f"{run_id['status']} {run_id['conclusion'] or ''}".strip()
                if state != last:
                    log(f"   {time.strftime('%H:%M')} {state}")
                    last = state
                if run_id["status"] == "completed":
                    return run_id["conclusion"] == "success", run_id["url"]
            time.sleep(30)
    except KeyboardInterrupt:
        log()
    return None, run_id["url"] if run_id else None


def release_state():
    """What main has that the last release does not: (head sha, current version, change lines)."""
    run(["git", "fetch", "-q", "--tags", "origin", "main"])
    head = run(["git", "rev-parse", "origin/main"]).stdout.strip()
    current = latest_version(run(["git", "tag", "--list", "v*"]).stdout.split())
    changes = run(["git", "log", "--no-merges", "--pretty=%s", f"{tag_name(current)}..{head}"]).stdout.split("\n")
    return head, current, [c for c in changes if c.strip()]


def check_tag(tag, current):
    if not parse_version(tag) or parse_version(tag) <= current:
        raise SystemExit(f"✗ {tag} ist keine gültige neue Version (aktuell {tag_name(current)}).")
    if run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"], check=False).returncode == 0:
        raise SystemExit(f"✗ {tag} gibt es schon.")


def check_locally(head):
    """Full verification of exactly this commit in its own working copy."""
    tree = WORK / "release"
    if tree.exists():
        run(["git", "worktree", "remove", "--force", str(tree)], check=False)
    WORK.mkdir(parents=True, exist_ok=True)
    run(["git", "worktree", "add", "-q", "--detach", str(tree), head])
    (tree / ".bugfix").mkdir(exist_ok=True)
    results = checks(tree)
    if not all(ok for _, ok, _ in results):
        name, _, out = next(r for r in results if not r[1])
        raise SystemExit(f"✗ {name} fehlgeschlagen – nichts veröffentlicht. Arbeitskopie: {tree}\n{out}")
    run(["git", "worktree", "remove", "--force", str(tree)], check=False)


def fixed_since(last, tag, merged=()):
    bodies = run(["git", "log", "--format=%B", f"{last}..{tag}"]).stdout
    return linked_issues(bodies, *(p["body"] for p in merged))


def notify(issues, tag, repo):
    for n in issues:
        run(["gh", "issue", "comment", str(n), "--repo", repo, "--body",
             f"Behoben in 6axis {tag[1:]}. Das Update bietet 6axis automatisch an "
             f"(oder: https://github.com/{repo}/releases/tag/{tag})."], check=False)
        run(["gh", "issue", "edit", str(n), "--repo", repo, "--remove-label", "fix-bereit"], check=False)
    log(f"✓ Melder benachrichtigt: {', '.join(f'#{n}' for n in issues)}")


def publish(tag, text, head, repo):
    """Tags, pushes, waits for the workflow and verifies. True only when published and verified."""
    run(["git", "tag", "-a", tag, head, "-m", f"6axis {tag[1:]} – {text}"])
    run(["git", "push", "-q", "origin", tag])
    log(f"✓ Tag {tag} gepusht.")
    ok, url = wait_for_release(tag, repo)
    if ok is None:
        return False
    if not ok:
        log(f"✗ Der Release-Lauf ist fehlgeschlagen: {url}\n  Nichts wurde veröffentlicht. Ursache beheben, dann:"
            f"\n  git push --delete origin {tag} && git tag -d {tag}   und erneut veröffentlichen.")
        return False
    log("Prüfe die veröffentlichten Dateien …")
    if not verify(tag, repo):
        log("✗ Die Prüfung hat Fehler gefunden – bitte ansehen, bevor Nutzer das Update installieren.")
        return False
    log(f"✓ {tag} ist veröffentlicht und geprüft.")
    return True


def release(repo, merged, dry_run):
    head, current, changes = release_state()
    last = tag_name(current)
    if not changes:
        log(f"\nmain enthält nichts Neues seit {last} – kein Release nötig.")
        return
    log(f"\nNoch nicht veröffentlicht (seit {last}):\n" + "\n".join(f"- {c}" for c in changes))
    if not yes("\nJetzt eine neue Version veröffentlichen?"):
        return

    kinds = {k: tag_name(next_version(current, kind)) for k, kind in (("1", "patch"), ("2", "minor"), ("3", "major"))}
    c = ask("Welche Version?", {"1": f"{kinds['1']} Fehlerbehebung", "2": f"{kinds['2']} neue Funktionen",
                                "3": f"{kinds['3']} große Änderung", "e": "eigene"}, "1")
    tag = kinds.get(c) or ask("Version (z. B. v2.1.0)")
    check_tag(tag, current)

    fixed = linked_issues(*(p["body"] for p in merged))
    default = "Fehlerbehebungen" + (f" ({', '.join(f'#{n}' for n in fixed)})" if fixed else "")
    text = ask("Kurzbeschreibung (deutsch, steht im Tag)", default=default)

    if yes("Vorher genau diesen Stand hier auf dem Mac prüfen (Tests, Build, Oberflächenprüfung – ca. 10 Minuten)?"):
        check_locally(head)

    log(f"\n{tag} – „{text}“ – Stand {head[:7]}")
    if dry_run:
        log("(Probelauf) würde jetzt taggen und pushen.")
        return
    if not confirm_public(f"{tag} jetzt veröffentlichen? Danach bekommen alle das Update angeboten."):
        log("Abgebrochen – nichts veröffentlicht.")
        return
    if not publish(tag, text, head, repo):
        return
    issues = fixed_since(last, tag, merged)
    if issues and yes(f"Melder von {', '.join(f'#{n}' for n in issues)} benachrichtigen („Behoben in {tag}“)?"):
        notify(issues, tag, repo)


# MARK: Without questions (used by the menu bar app "6axis Wartung")

def status(repo, owner):
    """Everything the menu bar app shows, as one JSON object."""
    from bugfix import bug_list, load_main_config
    prs = gh_json("pr", "list", "--repo", repo, "--state", "open", "--limit", "50", "--json", PR_FIELDS)
    head, current, changes = release_state()
    return {
        "repo": repo,
        "bugs": bug_list(repo, owner, load_main_config()),
        "prs": [{"number": p["number"], "title": p["title"], "url": p["url"], "author": p["author"]["login"],
                 "head": p["headRefOid"], "issues": linked_issues(p["body"]), "ci": ci_state(p["statusCheckRollup"]),
                 "additions": p["additions"], "deletions": p["deletions"], "files": len(p["files"] or []),
                 "blockers": review_notes(p, owner)[0], "warnings": review_notes(p, owner)[1]} for p in prs],
        "release": {"last": tag_name(current), "head": head, "changes": changes,
                    "next": {k: tag_name(next_version(current, k)) for k in ("patch", "minor", "major")}},
    }


def merge_now(n, head, repo, owner, accept_warnings):
    pr = gh_json("pr", "view", str(n), "--repo", repo, "--json", PR_FIELDS)
    if pr["headRefOid"] != head:
        raise SystemExit(f"✗ #{n} hat sich seit dem Ansehen geändert – bitte neu laden und prüfen.")
    blockers, warnings = review_notes(pr, owner)
    if blockers:
        raise SystemExit("✗ Nicht mergebar: " + "; ".join(blockers))
    if warnings and not accept_warnings:
        raise SystemExit("✗ Hinweise nicht bestätigt: " + "; ".join(warnings))
    if not merge(pr, repo, False):
        sys.exit(1)


def publish_now(tag, text, head, repo, local_check, notify_reporters):
    expected, current, changes = release_state()
    if head != expected:
        raise SystemExit("✗ main hat sich seit dem Ansehen geändert – bitte neu laden.")
    if not changes:
        raise SystemExit("✗ Nichts Neues seit dem letzten Release.")
    check_tag(tag, current)
    if local_check:
        check_locally(head)
    if not publish(tag, text, head, repo):
        sys.exit(1)
    issues = fixed_since(tag_name(current), tag)
    if issues and notify_reporters:
        notify(issues, tag, repo)


# MARK: Main

def main(argv=None):
    if os.environ.get("SIXAXIS_WARTUNG"):
        os.setpgrp()  # started by the menu bar app: own process group, so "Abbrechen" also stops builds and Claude
    p = argparse.ArgumentParser(description="Merge pull requests and publish a release")
    p.add_argument("--dry-run", action="store_true", help="only show, change nothing")
    p.add_argument("--verify", metavar="TAG", help="only check a published release")
    g = p.add_argument_group("without questions (menu bar app)")
    g.add_argument("--status-json", action="store_true", help="bugs, pull requests and release state as JSON")
    g.add_argument("--merge", type=int, metavar="PR", help="merge this pull request (needs --head)")
    g.add_argument("--head", help="commit that was reviewed (pull request or main)")
    g.add_argument("--accept-warnings", action="store_true")
    g.add_argument("--close", type=int, metavar="PR", help="discard this pull request (needs --reason)")
    g.add_argument("--reason")
    g.add_argument("--try", dest="try_pr", type=int, metavar="PR", help="build the app from this pull request and open it")
    g.add_argument("--publish", metavar="TAG", help="publish main as TAG (needs --head and --text)")
    g.add_argument("--text")
    g.add_argument("--check", action="store_true", help="with --publish: full local check first")
    g.add_argument("--notify", action="store_true", help="with --publish: comment 'fixed in …' on the issues")
    args = p.parse_args(argv)

    for tool in ("gh", "git"):
        if not shutil.which(tool):
            raise SystemExit(f"✗ {tool} fehlt")
    if run(["gh", "auth", "status"], check=False).returncode != 0:
        raise SystemExit("✗ GitHub-CLI nicht angemeldet: gh auth login")
    repo = run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).stdout.strip()
    owner = repo.split("/")[0]
    me = run(["gh", "api", "user", "-q", ".login"]).stdout.strip()
    if me.lower() != owner.lower():
        raise SystemExit(f"✗ Angemeldet als @{me} – mergen und veröffentlichen darf nur @{owner}.")

    if args.verify:
        sys.exit(0 if verify(args.verify, repo) else 1)
    if args.status_json:
        print(json.dumps(status(repo, owner), ensure_ascii=False))
        return
    if args.merge:
        if not args.head:
            raise SystemExit("✗ --merge braucht --head")
        return merge_now(args.merge, args.head, repo, owner, args.accept_warnings)
    if args.close:
        pr = gh_json("pr", "view", str(args.close), "--repo", repo, "--json", PR_FIELDS)
        return close(pr, repo, False, reason=args.reason or "Die automatische Korrektur passt so nicht.")
    if args.try_pr:
        return try_out(gh_json("pr", "view", str(args.try_pr), "--repo", repo, "--json", PR_FIELDS))
    if args.publish:
        if not (args.head and args.text):
            raise SystemExit("✗ --publish braucht --head und --text")
        return publish_now(args.publish, args.text, args.head, repo, args.check, args.notify)

    if args.dry_run:
        log("Probelauf – es wird nichts geändert.\n")
    try:
        merged = review_prs(repo, owner, args.dry_run)
        release(repo, merged, args.dry_run)
    except (KeyboardInterrupt, EOFError):
        log("\nAbgebrochen.")
        sys.exit(130)
    local = run(["git", "branch", "--show-current"]).stdout.strip()
    if local == "main" and not run(["git", "status", "--porcelain"]).stdout.strip():
        run(["git", "pull", "-q", "--ff-only"], check=False)


if __name__ == "__main__":
    main()
