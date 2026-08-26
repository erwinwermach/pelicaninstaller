#!/usr/bin/env python3
"""modpack-manager CurseForge fallback patch.

Makes the plugin usable without a CurseForge API key:
- CurseForgeService never throws at construction; isAvailable() + graceful
  empty results instead.
- Browser pages skip the CurseForge live queries (static fallbacks already exist)
  and clamp setProvider('curseforge') to 'all'.
- CurseForge provider pill hidden in both blades.

Idempotent: exits 0 silently if already applied.
Usage: python3 modpack-cf-fallback.py <plugin-root-dir>
"""
import re
import sys


def main() -> int:
    root = sys.argv[1]
    svc = f"{root}/src/Services/CurseForgeService.php"
    page_modpack = f"{root}/src/Filament/Server/Pages/ModpackBrowserPage.php"
    page_mod = f"{root}/src/Filament/Server/Pages/ModBrowserPage.php"
    blade_modpack = f"{root}/resources/views/filament/server/pages/modpack-browser-page.blade.php"
    blade_mod = f"{root}/resources/views/filament/server/pages/mod-browser-page.blade.php"

    src = open(svc, encoding="utf-8").read()
    if "function isAvailable" in src:
        return 0  # already patched

    edits = 0

    # 1. property + constructor
    new, n = re.subn(r"    private PendingRequest \$client;",
                     "    private PendingRequest $client;\n\n    private bool $available;",
                     src, count=1)
    if n != 1:
        print(f"FAIL: PendingRequest property not found in {svc}")
        return 1
    src, edits = new, edits + n

    new, n = re.subn(
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
        print(f"FAIL: constructor not found in {svc}")
        return 1
    src, edits = new, edits + n

    # 2. isAvailable() after constructor
    new, n = re.subn(
        r"        \]\)->baseUrl\(self::BASE_URL\)->timeout\(30\);\n    \}\n",
        "        ])->baseUrl(self::BASE_URL)->timeout(30);\n    }\n\n"
        "    public function isAvailable(): bool\n"
        "    {\n"
        "        return $this->available;\n"
        "    }\n",
        src, count=1)
    if n != 1:
        print(f"FAIL: constructor tail not found in {svc}")
        return 1
    src, edits = new, edits + n

    # 3. graceful guards on every public API method
    guards = {
        "search|searchContent|getMinecraftVersions|getCategories|getMod|getFiles|getFile|getFilesByIds|getModClasses": "return [];",
        "findServerPackForFile": "return null;",
        "getDownloadUrl": "return '';",
    }
    for names, ret in guards.items():
        pat = re.compile(r"(public function (?:%s)\([^)]*\)(?:: [\w?]+)?\n    \{)" % names)
        new, n = pat.subn(lambda m: m.group(1) + f"\n        if (!$this->available) {{ {ret} }}", src)
        if n < 1:
            print(f"FAIL: no methods matched ({names}) in {svc}")
            return 1
        src, edits = new, edits + n

    open(svc, "w", encoding="utf-8").write(src)
    print(f"patched CurseForgeService.php ({edits} edits)")

    # 4. ModpackBrowserPage: guarded version options
    src = open(page_modpack, encoding="utf-8").read()
    edits = 0
    new, n = re.subn(
        r"        \$versions = app\(CurseForgeService::class\)->getMinecraftVersions\(\);",
        "        $cf = app(CurseForgeService::class);\n"
        "        $versions = $cf->isAvailable() ? $cf->getMinecraftVersions() : [];",
        src, count=1)
    if n != 1:
        print(f"FAIL: getFilterVersionOptions not found in {page_modpack}")
        return 1
    src, edits = new, edits + n

    new, n = re.subn(
        r"        \$categories = app\(CurseForgeService::class\)->getCategories\(\);",
        "        $cf = app(CurseForgeService::class);\n"
        "        $categories = $cf->isAvailable() ? $cf->getCategories() : [];",
        src, count=1)
    if n != 1:
        print(f"FAIL: getFilterCategoryOptions not found in {page_modpack}")
        return 1
    src, edits = new, edits + n

    new, n = re.subn(
        r"    public function setProvider\(string \$provider\): void\n    \{\n        \$this->provider = \$provider;",
        "    public function setProvider(string $provider): void\n"
        "    {\n"
        "        if ($provider === 'curseforge' && !app(CurseForgeService::class)->isAvailable()) {\n"
        "            $provider = 'all';\n"
        "        }\n"
        "        $this->provider = $provider;",
        src, count=1)
    if n != 1:
        print(f"FAIL: setProvider not found in {page_modpack}")
        return 1
    src, edits = new, edits + n

    open(page_modpack, "w", encoding="utf-8").write(src)
    print(f"patched ModpackBrowserPage.php ({edits} edits)")

    # 5. ModBrowserPage: clamp setProvider
    src = open(page_mod, encoding="utf-8").read()
    edits = 0
    new, n = re.subn(
        r"    public function setProvider\(string \$provider\): void\n    \{\n        \$this->provider = in_array\(\$provider, \['all', 'curseforge', 'modrinth'\], true\) \? \$provider : 'all';",
        "    public function setProvider(string $provider): void\n"
        "    {\n"
        "        if ($provider === 'curseforge' && !app(CurseForgeService::class)->isAvailable()) {\n"
        "            $provider = 'all';\n"
        "        }\n"
        "        $this->provider = in_array($provider, ['all', 'curseforge', 'modrinth'], true) ? $provider : 'all';",
        src, count=1)
    if n != 1:
        print(f"FAIL: setProvider not found in {page_mod}")
        return 1
    src, edits = new, edits + n
    open(page_mod, "w", encoding="utf-8").write(src)
    print(f"patched ModBrowserPage.php ({edits} edits)")

    # 6. blades: hide CurseForge pill
    cond = "@if(app(\\Cosmii02\\ModpackManager\\Services\\CurseForgeService::class)->isAvailable())"
    for blade in (blade_modpack, blade_mod):
        bsrc = open(blade, encoding="utf-8").read()
        pat = re.compile(r"^(\s*)(<button type=\"button\" wire:click=\"setProvider\('curseforge'\)\".*)$", re.M)
        new, n = pat.subn(lambda m: m.group(1) + cond + "\n" + m.group(1) + m.group(2) + "\n" + m.group(1) + "@endif", bsrc)
        if n != 1:
            print(f"FAIL: CurseForge pill not found in {blade}")
            return 1
        open(blade, "w", encoding="utf-8").write(new)
        print(f"patched {blade} (1 edit)")

    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())