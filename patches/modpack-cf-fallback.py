#!/usr/bin/env python3
"""modpack-manager CurseForge fallback patch.

Makes the plugin usable without a CurseForge API key:
- CurseForgeService never throws at construction; isAvailable() + graceful
  empty results instead.
- Browser pages skip the CurseForge live queries (static fallbacks already exist)
  and clamp setProvider('curseforge') to 'all'.
- CurseForge provider pill hidden in both blades.

Idempotent and per-file: every target is checked and patched independently, so a
partially patched plugin tree is completed on the next run. Writes are atomic
(temp file + rename) and each file is only written once all of its edits applied.
Usage: python3 modpack-cf-fallback.py <plugin-root-dir>
"""
import os
import re
import sys
import tempfile


def fail(msg):
    print("FAIL: %s" % msg)
    return False


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return None


def write_atomic(path, data):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".cfpatch-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def patch_service(path):
    src = read(path)
    if src is None:
        return fail("missing %s" % path)
    if "function isAvailable" in src:
        return True

    # 1. property + constructor
    src, n = re.subn(r"    private PendingRequest \$client;",
                     "    private PendingRequest $client;\n\n    private bool $available;",
                     src, count=1)
    if n != 1:
        return fail("PendingRequest property not found in %s" % path)

    src, n = re.subn(
        r"        \$apiKey = config\('modpack-manager\.curseforge_api_key'\);\n\n"
        r"        if \(empty\(\$apiKey\)\) \{\n"
        r"            throw new RuntimeException\('CurseForge API key is not configured\.[^;]+;\n"
        r"        \}\n\n"
        r"        \$this->client = Http::withHeaders\(\[",
        "        $apiKey = config('modpack-manager.curseforge_api_key');\n\n"
        "        $this->available = !empty($apiKey);\n\n"
        "        if (!$this->available) {\n"
        "            return;\n"
        "        }\n\n"
        "        $this->client = Http::withHeaders([",
        src, count=1)
    if n != 1:
        return fail("constructor not found in %s" % path)

    # 2. isAvailable() after constructor
    src, n = re.subn(
        r"        \]\)->baseUrl\(self::BASE_URL\)->timeout\(30\);\n    \}\n",
        "        ])->baseUrl(self::BASE_URL)->timeout(30);\n    }\n\n"
        "    public function isAvailable(): bool\n"
        "    {\n"
        "        return $this->available;\n"
        "    }\n",
        src, count=1)
    if n != 1:
        return fail("constructor tail not found in %s" % path)

    # 3. graceful guards on every public API method (v1.6.12 adds
    #    getContentCategories and getDescription)
    guards = {
        "search|searchContent|getMinecraftVersions|getCategories|getContentCategories|getMod|getFiles|getFile|getFilesByIds|getModClasses": "return [];",
        "findServerPackForFile": "return null;",
        "getDownloadUrl|getDescription": "return '';",
    }
    for names, ret in guards.items():
        pat = re.compile(r"(public function (?:%s)\([^)]*\)(?:: [\w?]+)?\n    \{)" % names)
        src, n = pat.subn(lambda m: m.group(1) + "\n        if (!$this->available) { %s }" % ret, src)
        if n < 1:
            return fail("no methods matched (%s) in %s" % (names, path))

    try:
        write_atomic(path, src)
    except OSError as exc:
        return fail("cannot write %s (%s)" % (path, exc))
    print("patched %s" % path)
    return True


def patch_modpack_page(path):
    src = read(path)
    if src is None:
        return fail("missing %s" % path)
    if "!app(CurseForgeService::class)->isAvailable()" in src:
        return True

    # Guard the CurseForge call sites; newer releases already wrap them in
    # try/catch, so these two edits are best-effort and only applied when the
    # unguarded shape is present.
    src, n_versions = re.subn(
        r"        \$versions = app\(CurseForgeService::class\)->getMinecraftVersions\(\);",
        "        $cf = app(CurseForgeService::class);\n"
        "        $versions = $cf->isAvailable() ? $cf->getMinecraftVersions() : [];",
        src, count=1)
    src, n_categories = re.subn(
        r"        \$categories = app\(CurseForgeService::class\)->getCategories\(\);",
        "        $cf = app(CurseForgeService::class);\n"
        "        $categories = $cf->isAvailable() ? $cf->getCategories() : [];",
        src, count=1)

    clamp = ("        if ($provider === 'curseforge' && !app(CurseForgeService::class)->isAvailable()) {\n"
             "            $provider = 'all';\n"
             "        }\n")
    # v1.6.12+ validates the provider against an allow-list before assigning it.
    src, n_clamp = re.subn(
        r"(public function setProvider\(string \$provider\): void\n    \{\n        if \(!in_array\(\$provider, \[[^\]]*\], true\)\) \{\n            return;\n        \}\n)",
        lambda m: m.group(1) + "\n" + clamp, src, count=1)
    if n_clamp != 1:
        src, n_clamp = re.subn(
            r"    public function setProvider\(string \$provider\): void\n    \{\n        \$this->provider = \$provider;",
            "    public function setProvider(string $provider): void\n    {\n" + clamp + "        $this->provider = $provider;",
            src, count=1)
    if n_clamp != 1:
        return fail("setProvider not found in %s" % path)

    try:
        write_atomic(path, src)
    except OSError as exc:
        return fail("cannot write %s (%s)" % (path, exc))
    print("patched %s (call-site guards: versions=%d categories=%d)" % (path, n_versions, n_categories))
    return True


def patch_mod_page(path):
    src = read(path)
    if src is None:
        return fail("missing %s" % path)
    if "!app(CurseForgeService::class)->isAvailable()" in src:
        return True

    src, n = re.subn(
        r"    public function setProvider\(string \$provider\): void\n    \{\n        \$this->provider = in_array\(\$provider, \['all', 'curseforge', 'modrinth'\], true\) \? \$provider : 'all';",
        "    public function setProvider(string $provider): void\n"
        "    {\n"
        "        if ($provider === 'curseforge' && !app(CurseForgeService::class)->isAvailable()) {\n"
        "            $provider = 'all';\n"
        "        }\n"
        "        $this->provider = in_array($provider, ['all', 'curseforge', 'modrinth'], true) ? $provider : 'all';",
        src, count=1)
    if n != 1:
        return fail("setProvider not found in %s" % path)

    try:
        write_atomic(path, src)
    except OSError as exc:
        return fail("cannot write %s (%s)" % (path, exc))
    print("patched %s" % path)
    return True


def patch_blade(path):
    src = read(path)
    if src is None:
        return fail("missing %s" % path)
    if "->isAvailable())" in src:
        return True

    cond = "@if(app(\\Cosmii02\\ModpackManager\\Services\\CurseForgeService::class)->isAvailable())"
    pat = re.compile(r"^(\s*)(<button type=\"button\" wire:click=\"setProvider\('curseforge'\)\".*)$", re.M)
    src, n = pat.subn(lambda m: m.group(1) + cond + "\n" + m.group(1) + m.group(2) + "\n" + m.group(1) + "@endif", src)
    if n != 1:
        return fail("CurseForge pill not found in %s" % path)

    try:
        write_atomic(path, src)
    except OSError as exc:
        return fail("cannot write %s (%s)" % (path, exc))
    print("patched %s" % path)
    return True


def main():
    if len(sys.argv) < 2:
        print("usage: modpack-cf-fallback.py <plugin-root-dir>")
        return 2
    root = sys.argv[1]
    targets = [
        (os.path.join(root, "src", "Services", "CurseForgeService.php"), patch_service),
        (os.path.join(root, "src", "Filament", "Server", "Pages", "ModpackBrowserPage.php"), patch_modpack_page),
        (os.path.join(root, "src", "Filament", "Server", "Pages", "ModBrowserPage.php"), patch_mod_page),
        (os.path.join(root, "resources", "views", "filament", "server", "pages", "modpack-browser-page.blade.php"), patch_blade),
        (os.path.join(root, "resources", "views", "filament", "server", "pages", "mod-browser-page.blade.php"), patch_blade),
    ]
    ok = True
    for path, fn in targets:
        try:
            if not fn(path):
                ok = False
        except Exception as exc:  # never leave the caller without a clear status
            print("FAIL: unexpected error patching %s (%s)" % (path, exc))
            ok = False
    if not ok:
        print("Some files could not be patched - retrying on the next heal/update run.")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
