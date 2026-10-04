"""Pakiet do GAMA ze strony (zakładka GAMA): kopia models/Hall_AC_aversion.gaml z ustawieniami ze strony, sieć i krzewy
w SHP, skrypty uruchomienia (headless) i opis. Tylko biblioteka standardowa (działa w Pyodide). Nie zmienia modelu:
ustawienia trafiają do KOPII pliku .gaml przez podmianę stałych, jak w udi_docking.gaml_copy.

Użycie w Pythonie:  zip_bytes, report = gama_export.package(model, params, gaml_text, seeds)
"""
import hashlib
import io
import json
import re
import struct
import zipfile

# PUWG 1992 (EPSG:2180); przesunięcie, żeby GAMA nie wzięła małych współrzędnych metrycznych za stopnie
PRJ = ('PROJCS["ETRS89 / Poland CS92",GEOGCS["ETRS89",DATUM["European_Terrestrial_Reference_System_1989",'
       'SPHEROID["GRS 1980",6378137,298.257222101]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],'
       'PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",19],'
       'PARAMETER["scale_factor",0.9993],PARAMETER["false_easting",500000],PARAMETER["false_northing",-5300000],'
       'UNIT["metre",1]]')
OFFSET = (360000.0, 360000.0)
EXPERIMENT = "Hall"


def _num(v):
    return repr(float(v))


def _bool(v):
    return "true" if v else "false"


# (parametr strony, wzorzec w GAML, zamiana); wzorzec musi trafić dokładnie tyle razy, ile podano (count)
def _rules(p):
    r = [
        ("step_min", r"float step <- [0-9.eE+-]+ #mn;", "float step <- %s #mn;" % _num(p["step_min"]), 1),
        ("hall_multiplier", r"float hall_multiplier <- [0-9.eE+-]+;", "float hall_multiplier <- %s;" % _num(p["hall_multiplier"]), 1),
        ("aversion_strength", r"float aversion_strength <- [0-9.eE+-]+;", "float aversion_strength <- %s;" % _num(p["aversion_strength"]), 1),
        ("fear_deposit", r"float fear_deposit <- [0-9.eE+-]+;", "float fear_deposit <- %s;" % _num(p["fear_deposit"]), 1),
        ("fear_decay", r"fear_decay <- [0-9.eE+-]+;", "fear_decay <- %s;" % _num(p["fear_decay"]), 1),
        ("reweight_every", r"int reweight_every <- [0-9]+;", "int reweight_every <- %d;" % int(p["reweight_every"]), 1),
        ("phantom_nb", r"int phantom_nb <- [0-9]+;", "int phantom_nb <- %d;" % int(p["phantom_nb"]), 1),
        ("bot_nb", r"int bot_nb <- [0-9]+;", "int bot_nb <- %d;" % int(p["bot_nb"]), 1),
        ("bot_graph", r"bool bots_plain_graph <- \w+;", "bool bots_plain_graph <- %s;" % _bool(p["bot_graph"] == "plain"), 1),
        ("fear_scope", r"bool individual_fear <- \w+;", "bool individual_fear <- %s;" % _bool(p["fear_scope"] == "individual"), 1),
        ("bot_speed_kmh", r"speed <- [0-9.]+ #km/#h \+ gauss\(0,\s*[0-9.]+\);",
         "speed <- %s #km/#h + gauss(0,%s);" % (_num(p["bot_speed_kmh"]), _num(p["bot_speed_sd"])), 1),
        ("phantom_speed_kmh", r"speed <- [0-9.]+ #km/#h ;", "speed <- %s #km/#h ;" % _num(p["phantom_speed_kmh"]), 1),
        ("adrenaline_threshold", r"if \(adrenaline > [0-9.]+\)", "if (adrenaline > %s)" % _num(p["adrenaline_threshold"]), 1),
        ("fear_spacing", r"empty\(fear at_distance [0-9.]+\)", "empty(fear at_distance %s)" % _num(p["fear_spacing"]), 1),
        ("adrenaline_cooldown", r"float adrenaline_cooldown <- [0-9.]+;", "float adrenaline_cooldown <- %s;" % _num(p["adrenaline_cooldown"]), 1),
        ("cortisol_cooldown", r"float cortisol_cooldown <- [0-9.]+;", "float cortisol_cooldown <- %s;" % _num(p["cortisol_cooldown"]), 1),
        ("cortisol_gain", r"cortisol <- cortisol \+ [0-9.]+\*adrenaline", "cortisol <- cortisol + %s*adrenaline" % _num(p["cortisol_gain"]), 1),
        ("initial_level", r"float (vigilance|adrenaline|cortisol) <- [0-9.]+;",
         lambda m: "float %s <- %s;" % (m.group(1), _num(p["initial_level"])), 3),
        ("end_cycle", r"cycle >= [0-9]+\)", "cycle >= %d)" % int(p["end_cycle"]), 1),
        ("end_cycle", r"when: cycle = [0-9]+ \{", "when: cycle = %d {" % (int(p["end_cycle"]) - 1), 1),
        ("end_cycle", r"autosave: cycle=[0-9]+", "autosave: cycle=%d" % int(p["end_cycle"]), 1),
    ]
    for z, k in (("intimate", 0.45), ("personal", 1.2), ("social", 3.6), ("public", 10.0)):
        if p.get(z) is not None:
            r.append((z, r"float %s\s*<-\s*[^;]+;" % z, "float %s <- %s;" % (z, _num(p[z])), 1))
    return r


# parametry, które zapisuje geometria w SHP, i te, których GAML nie ma
IN_SHP = ("park", "park_seed", "park_width", "park_height", "park_bushes", "planting", "planting_seed", "bush_area_total",
          "bush_form", "bush_radius", "bush_band_width", "bush_band_length", "bush_junction_share", "bush_junction_distance",
          "bush_path_offset", "bush_setback_scope", "junction_zone", "largest_component")
NOT_IN_GAMA = ("isovist_spacing", "isovist_rays", "isovist_radius")


def gaml_copy(src, p, roads_shp, obst_shp):
    """Kopia modelu z ustawieniami p. Zwraca (tekst, raport); każda podmiana jest sprawdzana (regex bez trafienia
    po cichu zostawiłby starą wartość)."""
    s = src.replace('"Staszica_SHP_sciezki_01.shp"', '"%s"' % roads_shp).replace('"Staszica_SHP_krzaki_09.shp"', '"%s"' % obst_shp)
    if roads_shp not in s or obst_shp not in s:
        raise ValueError("w pliku .gaml nie ma nazw plików SHP Parku Staszica")
    done = {}
    for key, pat, rep, count in _rules(p):
        s, n = re.subn(pat, rep, s)
        if n != count:
            raise ValueError("GAML: %s – oczekiwano %d trafień wzorca, jest %d" % (key, count, n))
        done[key] = p[key] if key in p else None
    # seed przebiegu jako parametr run_seed (tylko w kopii): ten sam w planie headless i przy połączeniu z serwerem GAMA,
    # ustawiany na początku init, zanim model cokolwiek losuje; zapisywany w summary.csv do parowania z Pythonem
    s, n0 = re.subn(r"\n(\s*)init \{\n", "\n\\1// seed przebiegu ze strony (0 = seed eksperymentu)\n\\1float run_seed <- 0.0;\n"
                    "\\1init {\n\\1    if (run_seed > 0) { seed <- run_seed; }\n", s, count=1)
    s, n1 = re.subn(r"(experiment %s\s+type: gui \{\n)" % EXPERIMENT, "\\1\tparameter \"run_seed\" var: run_seed;\n", s)
    if n0 != 1 or n1 != 1:
        raise ValueError("GAML: nie znaleziono init albo eksperymentu %s" % EXPERIMENT)
    s, n = re.subn(r"save \[\s*myself\.bot_nb,", "save [\n            (myself.run_seed > 0 ? myself.run_seed : world.seed),\n            myself.bot_nb,", s)
    s, n2 = re.subn(r'header: \["bot_nb",', 'header: ["seed", "bot_nb",', s)
    if n != 1 or n2 != 1:
        raise ValueError("GAML: nie znaleziono zapisu summary.csv")
    report = []
    for k, v in p.items():
        if k in done or k in ("bot_speed_sd",):
            report.append([k, v, "gaml"])
        elif k in IN_SHP:
            report.append([k, v, "shp"])
        elif k in NOT_IN_GAMA:
            report.append([k, v, "python"])
        elif k in ("intimate", "personal", "social", "public"):
            report.append([k, v, "gaml"])
        else:
            report.append([k, v, "unknown"])
    return s, report


# ---------- SHP bez bibliotek (polilinie i wielokąty, układ metryczny) ----------
def _shp(shape_type, parts_list):
    """parts_list: [[[ (x, y), ... ] części], ...] -> (shp, shx)"""
    recs, offs = [], []
    allpts = [q for parts in parts_list for part in parts for q in part]
    bbox = (min(q[0] for q in allpts), min(q[1] for q in allpts), max(q[0] for q in allpts), max(q[1] for q in allpts)) if allpts else (0, 0, 0, 0)
    pos = 100
    for i, parts in enumerate(parts_list):
        pts = [q for part in parts for q in part]
        bb = (min(q[0] for q in pts), min(q[1] for q in pts), max(q[0] for q in pts), max(q[1] for q in pts))
        body = struct.pack("<i4d2i", shape_type, *bb, len(parts), len(pts))
        start = 0
        for part in parts:
            body += struct.pack("<i", start)
            start += len(part)
        for q in pts:
            body += struct.pack("<2d", q[0], q[1])
        recs.append(struct.pack(">2i", i + 1, len(body) // 2) + body)
        offs.append((pos // 2, len(body) // 2))
        pos += 8 + len(body)

    def header(length_bytes):
        return (struct.pack(">7i", 9994, 0, 0, 0, 0, 0, length_bytes // 2) + struct.pack("<2i", 1000, shape_type)
                + struct.pack("<4d", *bbox) + struct.pack("<4d", 0, 0, 0, 0))
    shp = header(pos) + b"".join(recs)
    shx = header(100 + 8 * len(offs)) + b"".join(struct.pack(">2i", o, n) for o, n in offs)
    return shp, shx


def _dbf(n):
    """Jedno pole numeryczne id."""
    head = struct.pack("<B3BIHH20x", 3, 126, 1, 1, n, 32 + 32 + 1, 1 + 10)
    field = b"id".ljust(11, b"\0") + b"N" + b"\0" * 4 + bytes([10, 0]) + b"\0" * 14
    rows = b"".join(b" " + str(i).rjust(10).encode() for i in range(n))
    return head + field + b"\r" + rows + b"\x1a"


def shp_files(base, roads, polys):
    """roads: [[(x, y), ...]], polys: [[pierścień, ...]] w metrach -> {nazwa pliku: bajty} dla obu warstw."""
    sh = lambda q: (q[0] + OFFSET[0], q[1] + OFFSET[1])
    out = {}
    for suf, typ, items in (("_sciezki", 3, [[[sh(q) for q in r]] for r in roads]),
                            ("_krzaki", 5, [[[sh(q) for q in ring] for ring in rings] for rings in polys])):
        shp, shx = _shp(typ, items)
        out[base + suf + ".shp"] = shp
        out[base + suf + ".shx"] = shx
        out[base + suf + ".dbf"] = _dbf(len(items))
        out[base + suf + ".prj"] = PRJ.encode()
    return out


# ---------- skrypty ----------
RUN_SH = """#!/bin/bash
# Uruchamia przebiegi w GAMA bez okna (headless). Użycie: bash run_gama.sh /sciezka/do/gama-platform
# (albo ustaw zmienną GAMA_HOME). Wyniki: @RESULTS@, jeden wiersz na phantoma i seed.
G="${1:-$GAMA_HOME}"
if [ -z "$G" ]; then echo "Podaj katalog GAMA, np. bash run_gama.sh /opt/gama-platform"; exit 1; fi
D="$(cd "$(dirname "$0")" && pwd)"
H="$G/headless/gama-headless.sh"
[ -f "$H" ] || H="$G/Contents/headless/gama-headless.sh"
[ -f "$H" ] || H="$G/Contents/Eclipse/headless/gama-headless.sh"
if [ ! -f "$H" ]; then echo "Nie znaleziono gama-headless.sh w $G"; exit 1; fi
mkdir -p "$D/results" "$D/out"
{
  echo "<Experiment_plan>"
  i=1
  for s in @SEEDS@; do
    echo "  <Simulation id=\\"$i\\" sourcePath=\\"$D/@MODEL@\\" finalStep=\\"@END@\\" experiment=\\"@EXP@\\" seed=\\"$s\\"><Parameters><Parameter name=\\"run_seed\\" type=\\"FLOAT\\" value=\\"$s\\"/></Parameters><Outputs/></Simulation>"
    i=$((i+1))
  done
  echo "</Experiment_plan>"
} > "$D/plan.xml"
cd "$G/headless" 2>/dev/null || true
bash "$H" -m 4g "$D/plan.xml" "$D/out"
echo "Gotowe: $D/@RESULTS@"
"""

RUN_BAT = """@echo off
rem Uruchamia przebiegi w GAMA bez okna (headless). Uzycie: run_gama.bat C:\\sciezka\\do\\GAMA
rem (albo ustaw zmienna GAMA_HOME). Wyniki: @RESULTS@
setlocal
set "G=%~1"
if "%G%"=="" set "G=%GAMA_HOME%"
if "%G%"=="" (echo Podaj katalog GAMA, np. run_gama.bat "C:\\Program Files\\Gama" & exit /b 1)
set "D=%~dp0"
if not exist "%D%results" mkdir "%D%results"
if not exist "%D%out" mkdir "%D%out"
> "%D%plan.xml" echo ^<Experiment_plan^>
set /a i=1
for %%s in (@SEEDS@) do call :sim %%s
>> "%D%plan.xml" echo ^</Experiment_plan^>
cd /d "%G%\\headless"
call "%G%\\headless\\gama-headless.bat" -m 4g "%D%plan.xml" "%D%out"
echo Gotowe: %D%@RESULTS@
exit /b 0
:sim
>> "%D%plan.xml" echo   ^<Simulation id="%i%" sourcePath="%D%@MODEL@" finalStep="@END@" experiment="@EXP@" seed="%1"^>^<Parameters^>^<Parameter name="run_seed" type="FLOAT" value="%1"/^>^</Parameters^>^<Outputs/^>^</Simulation^>
set /a i+=1
exit /b 0
"""

README = """Pakiet PSM do GAMA (wygenerowany przez stronę PSM)
==================================================

Zawartość
- @MODEL@   kopia models/Hall_AC_aversion.gaml z ustawieniami ze strony (zmienione są tylko stałe,
                       nazwy plików SHP, plik wyników i parametr run_seed); skrót w nazwie pochodzi z ustawień i parku
- park_*_sciezki.*     sieć ścieżek (SHP, metry, EPSG:2180 z przesunięciem)
- park_*_krzaki.*      krzewy i inne przeszkody (SHP)
- run_gama.sh          uruchomienie headless (Linux, macOS):  bash run_gama.sh /sciezka/do/gama-platform
- run_gama.bat         uruchomienie headless (Windows):       run_gama.bat C:\\sciezka\\do\\GAMA
- config_*.json        ustawienia, seedy, park i wersja modelu
- parametry_*.csv      które ustawienia trafiły do modelu, które są zapisane w SHP, a które działają tylko w Pythonie

Przebiegi: {n} (seedy {seeds}), po {end} cykli. Przebiegi z planu liczą się równolegle w jednej JVM;
jeden przebieg z 50–80 botami i 10 000 cykli to kilka minut.

Wyniki: @RESULTS@ (seed, bot_nb, phantom_nb, total_adrenaline, total_cortisol, total_vigilance).
Wczytaj ten plik w zakładce GAMA na stronie: pokaże wyniki GAMA obok Pythona z tymi samymi ustawieniami i seedami.

Połączenie ze stroną (bez ręcznego uruchamiania): rozpakuj paczkę, uruchom GAMA jako serwer
(headless/gama-headless.sh -socket 6868, w Windows gama-headless.bat -socket 6868) i podaj na stronie pełną ścieżkę
tego folderu. Kolejne paczki rozpakowuj do tego samego folderu.

W oknie GAMA: utwórz projekt (File > New > GAMA Project), skopiuj do jego katalogu models/ wszystkie pliki z tej paczki,
otwórz @MODEL@, ustaw parametr run_seed i uruchom eksperyment „{exp}”.

Seed przebiegu (run_seed) jest ten sam w obu trybach, więc ten sam seed daje w GAMA ten sam wynik. Generator liczb
losowych GAMA różni się od Pythona, więc pojedyncze przebiegi GAMA i Pythona nie będą identyczne; porównuj średnie.

---

PSM package for GAMA (generated by the PSM page)
- @MODEL@ is a copy of models/Hall_AC_aversion.gaml with the page settings (only constants, the SHP file names,
  the results file and a run_seed parameter are changed); park_*.shp hold the paths and the shrubs.
- Headless run: bash run_gama.sh /path/to/gama-platform (Linux, macOS) or run_gama.bat C:\\path\\to\\GAMA (Windows).
- Load @RESULTS@ in the GAMA tab of the page to see GAMA next to Python with the same settings and seeds.
- Connection mode: unzip, start GAMA as a server (gama-headless.sh -socket 6868) and give the page the folder's full path.
- GAMA and Python use different random number generators, so single runs differ; compare means over several seeds.
"""


def build(model, p, gaml_src):
    """Model GAML i SHP dla ustawień p -> (pliki {nazwa: bajty|tekst}, raport, info). Nazwy plików mają skrót
    zawartości (serwer GAMA trzyma skompilowane modele według ścieżki, więc nowe ustawienia = nowy plik)."""
    edges = model.net.active if p.get("largest_component", True) else model.net.edges
    roads = [list(e.pts) for e in edges]
    polys = [list(r) for r in model.obstacles.polygons]
    gaml, report = gaml_copy(gaml_src, p, "@ROADS@", "@OBST@")
    shp = shp_files("park", roads, polys)
    h = hashlib.sha256(gaml.encode() + b"".join(shp[k] for k in sorted(shp))).hexdigest()[:8]
    base = "park_" + h
    res = "results/summary_%s.csv" % h
    gaml = gaml.replace("@ROADS@", base + "_sciezki.shp").replace("@OBST@", base + "_krzaki.shp")
    gaml, n = re.subn(r'to: "results/summary\.csv"', 'to: "%s"' % res, gaml)
    if n != 1:
        raise ValueError("GAML: nie znaleziono pliku wyników results/summary.csv")
    files = {"model_%s.gaml" % h: gaml}
    files.update({base + k[len("park"):]: v for k, v in shp.items()})
    info = {"hash": h, "model_file": "model_%s.gaml" % h, "results": res, "edges": len(roads), "obstacles": len(polys),
            "experiment": EXPERIMENT}
    return files, report, info


def package(model, p, gaml_src, seeds, meta=None):
    """Zwraca (bajty ZIP, raport parametrów, info). model: psm.Model po inicjalizacji (geometria), p: parametry strony."""
    files, report, info = build(model, p, gaml_src)
    end = int(p["end_cycle"])
    seeds = [int(s) for s in seeds]
    sub = lambda t: (t.replace("@SEEDS@", " ".join(map(str, seeds))).replace("@END@", str(end)).replace("@EXP@", EXPERIMENT)
                     .replace("@MODEL@", info["model_file"]).replace("@RESULTS@", info["results"]))
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        root = "psm_gama/"
        for name, data in files.items():
            z.writestr(root + name, data)
        zi = zipfile.ZipInfo(root + "run_gama.sh")
        zi.external_attr = 0o755 << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, sub(RUN_SH))
        z.writestr(root + "run_gama.bat", sub(RUN_BAT).replace("\n", "\r\n"))
        z.writestr(root + "README.txt", sub(README).format(n=len(seeds), seeds=", ".join(map(str, seeds)), end=end, exp=EXPERIMENT))
        z.writestr(root + "results/.keep", "")
        cfg = dict(meta or {}, seeds=seeds, end_cycle=end, params=p, gama=info)
        z.writestr(root + "config_%s.json" % info["hash"], json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
        z.writestr(root + "parametry_%s.csv" % info["hash"], "parametr,wartosc,gdzie\n" + "".join(
            "%s,%s,%s\n" % (k, json.dumps(v) if not isinstance(v, str) else v, w) for k, v, w in report))
    return buf.getvalue(), report, info


def read_summary(text):
    """results/summary_*.csv z GAMA -> lista słowników (liczby jako float); znosi nagłówek powtórzony przy dopisywaniu."""
    rows, head = [], None
    for line in text.replace("\r", "").split("\n"):
        cells = [c.strip().strip('"') for c in line.split(",")]
        if not line.strip():
            continue
        if "total_adrenaline" in cells:
            # GAMA 1.9 pisze w nagłówku wyrażenia (world.seed, myself.bot_nb), nowsze wersje – nazwy z header:
            head = [c.split(".")[-1] for c in cells]
            continue
        if head is None:
            head = ["bot_nb", "phantom_nb", "total_adrenaline", "total_cortisol", "total_vigilance"][-len(cells):]
            if len(cells) == 6:
                head = ["seed"] + head
        try:
            rows.append({k: float(v) for k, v in zip(head, cells)})
        except ValueError:
            continue
    return rows
