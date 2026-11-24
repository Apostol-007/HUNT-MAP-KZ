"""Conservative source-tree credential scan, not a substitute for Git history scanning."""
from pathlib import Path
import re
import subprocess
import sys

PATTERNS = {
    "private-key-block": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "github-access-token": re.compile(r"\\b(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}"),
    "aws-access-key": re.compile(r"\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b"),
    "api-secret-token": re.compile(r"\\bsk-[A-Za-z0-9]{28,}\\b"),
}
EXTENSIONS = {".swift", ".py", ".yml", ".yaml", ".json", ".md", ".sh", ".bat", ".txt"}
ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\\0")
    findings = []
    examined = 0
    for raw in paths:
        if not raw:
            continue
        path = ROOT / raw.decode("utf-8", "replace")
        if path.suffix.lower() not in EXTENSIONS or not path.is_file() or path.stat().st_size > 1_000_000:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        examined += 1
        for name, regex in PATTERNS.items():
            for match in regex.finditer(text):
                line = text.count("\\n", 0, match.start()) + 1
                findings.append(f"{path.relative_to(ROOT)}:{line}: {name}")
    for finding in findings:
        print("Credential pattern found:", finding, file=sys.stderr)
    print(f"Scanned {examined} tracked text files; suspicious patterns: {len(findings)}")
    print("Note: historical commits and external deployment secrets are not scanned.")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
