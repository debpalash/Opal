# VERSION: 1.52

# Author:
#  Fabien Devaux <fab AT gnux DOT info>
# Contributors:
#  Christophe Dumez <chris@qbittorrent.org> (qbittorrent integration)
#  Thanks to gab #gcu @ irc.freenode.net (multipage support on PirateBay)
#  Thanks to Elias <gekko04@users.sourceforge.net> (torrentreactor and isohunt search engines)

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#    * Redistributions of source code must retain the above copyright notice,
#      this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#    * Neither the name of the author nor the names of its contributors may be
#      used to endorse or promote products derived from this software without
#      specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

import importlib
import pathlib
import sys
import traceback
import urllib.parse
import xml.etree.ElementTree as ET
from abc import ABC, abstractmethod
from collections.abc import Iterable
from enum import Enum
from glob import glob
from multiprocessing import Pool, TimeoutError as PoolTimeoutError, cpu_count
from os import path
from typing import Optional

# qbt tend to run this script in 'isolate mode' so append the current path manually
current_path = str(pathlib.Path(__file__).parent.resolve())
if current_path not in sys.path:
    sys.path.append(current_path)

import helpers
import novaprinter
import opal_sources

# enable SOCKS proxy for all plugins by default
helpers.enable_socks_proxy(True)

THREADED: bool = True
try:
    MAX_THREADS: int = cpu_count()
except NotImplementedError:
    MAX_THREADS = 1  # pyright: ignore[reportConstantRedefinition]

Category = Enum('Category', ['all', 'anime', 'books', 'games', 'movies', 'music', 'pictures', 'software', 'tv'])

EngineModuleName = str  # the filename of the engine plugin


class Engine(ABC):
    """
    The base class for a search engine

    An engine must implement a ``search()`` method taking a **space-free** string
    as argument (for example ``family+guy``)

    If the site requires special handling for downloading .torrent files, then a
    customized ``download_torrent()`` method must be implemented. For example:
    .. code-block:: python

        def download_torrent(self, url: str) -> None:
            print(helpers.download_file(url))

    """

    name: str
    url: str
    supported_categories: dict[str, str]

    @abstractmethod
    def search(self, query: str, category: str = Category.all.name) -> None:
        """
        Run the search query

        Usually it would call ``novaprinter.prettyPrinter()`` with a ``dict`` as an argument
        (or actually ``novaprinter.SearchResults``).
        Refer to ``novaprinter.SearchResults`` for the keys.

        When printing the search results, it is recommended to list the results by decreasing
        number of seeds, or some other criteria that is sensible to the end user.
        """

        #novaprinter.prettyPrinter()
        raise NotImplementedError


# global state
engine_dict: dict[EngineModuleName, Optional[type[Engine]]] = {}


def list_engines() -> list[EngineModuleName]:
    """
    List all engines

    Including broken engines that might fail on import.

    :return: A list of all engines' module name
    """

    names: list[EngineModuleName] = []

    for engine_path in glob(path.join(path.dirname(__file__), 'engines', '*.py')):
        engine_module_name = path.basename(engine_path).split('.')[0].strip()
        if len(engine_module_name) == 0 or engine_module_name.startswith('_'):
            continue
        names.append(engine_module_name)

    return sorted(names)


def installed_engines() -> set[str]:
    """Engine ids the user has explicitly installed via Opal's plugin manager
    (a `sources/<id>.json` marker). Opal ships NEUTRAL — with nothing installed
    this is empty and no engine runs, so no search source is live by default.

    The directory layout must mirror core/paths.zig configDir(), so it lives in
    opal_sources alongside the base/mirrors lookup that reads the same files —
    two copies of that path is how the two halves drift apart."""
    return opal_sources.installed_ids()


def import_engine(engine_module_name: EngineModuleName) -> Optional[type[Engine]]:
    if engine_module_name in engine_dict:
        return engine_dict[engine_module_name]

    # when import fails, return `None`
    engine_class = None
    try:
        # import engines.[engine_module_name]
        engine_module = importlib.import_module(f"engines.{engine_module_name}")
        engine_class = getattr(engine_module, engine_module_name)
    except Exception:
        pass

    engine_dict[engine_module_name] = engine_class
    return engine_class


def get_capabilities(engines: Iterable[EngineModuleName]) -> str:
    """
    Return capabilities in XML format

    For example:
    .. code-block:: xml

        <capabilities>
          <engine_module_name>
            <name>long name</name>
            <url>http://example.com</url>
            <categories>movies music games</categories>
          </engine_module_name>
        </capabilities>

    """

    capabilities_element = ET.Element('capabilities')

    for engine_module_name in engines:
        engine_class = import_engine(engine_module_name)
        if engine_class is None:
            continue

        engine_module_element = ET.SubElement(capabilities_element, engine_module_name)

        ET.SubElement(engine_module_element, 'name').text = engine_class.name
        ET.SubElement(engine_module_element, 'url').text = engine_class.url

        supported_categories = ""
        if hasattr(engine_class, "supported_categories"):
            supported_categories = " ".join((key
                                             for key in sorted(engine_class.supported_categories.keys())
                                             if key != Category.all.name))
        ET.SubElement(engine_module_element, 'categories').text = supported_categories

    ET.indent(capabilities_element)
    return ET.tostring(capabilities_element, 'unicode')


def run_search(search_params: tuple[type[Engine], str, Category, EngineModuleName]) -> bool:
    """
    Run search in engine

    :param search_params: A tuple with engine, query, category and module name.
    :return: ``False`` if any exceptions occurred. ``True`` otherwise.

    The engine's ``url`` is taken from the source the user installed
    (``sources/<module_name>.json``) rather than the class attribute, and each
    configured mirror is tried in turn until one returns rows — see
    opal_sources. With no source file, or one without a base, the engine keeps
    its own hardcoded URL and this is a plain single-host search.
    """

    engine_class, what, cat, module_name = search_params
    try:
        engine = engine_class()
        # avoid exceptions due to invalid category
        category = ''
        if hasattr(engine, 'supported_categories'):
            if cat.name not in engine.supported_categories:
                return True
            category = cat.name
        return opal_sources.search_with_failover(
            engine, module_name, what, category, novaprinter.printed_count)
    except Exception:
        traceback.print_exc()
        return False


if __name__ == "__main__":
    def main() -> int:
        # https://docs.python.org/3/library/sys.html#sys.exit
        class ExitCode(Enum):
            OK = 0
            AppError = 1
            ArgError = 2

        # Opal asks a large set of independent plugins to search in parallel.
        # A single scraper can still spend tens of seconds walking mirrors even
        # after fast API engines have printed plenty of useful rows.  Accept an
        # app-only deadline so the UI gets a bounded search without changing
        # qBittorrent-compatible invocations of this script.
        deadline: Optional[float] = None
        argv = sys.argv[1:]
        if argv and argv[0].startswith("--timeout="):
            try:
                deadline = max(1.0, float(argv[0].split("=", 1)[1]))
            except ValueError:
                print(f"Invalid timeout: {argv[0]}", file=sys.stderr)
                return ExitCode.ArgError.value
            argv = argv[1:]

        found_engines = list_engines()

        prog_name = sys.argv[0]
        prog_usage = (f"Usage: {prog_name} all|engine1[,engine2]* <category> <keywords>\n"
                      f"To list available engines: {prog_name} --capabilities [--names]\n"
                      f"Found engines: {','.join(found_engines)}")

        if "--capabilities" in sys.argv:
            if "--names" in sys.argv:
                print(",".join((e for e in found_engines if import_engine(e) is not None)))
                return ExitCode.OK.value

            print(get_capabilities(found_engines))
            return ExitCode.OK.value
        elif len(argv) < 3:
            print(prog_usage, file=sys.stderr)
            return ExitCode.ArgError.value

        # get unique engines
        engs = set(arg.strip().lower() for arg in argv[0].split(','))
        engines = found_engines if 'all' in engs else [e for e in found_engines if e in engs]
        # Neutral-player gate: only run engines the user has installed.
        installed = installed_engines()
        engines = [e for e in engines if e in installed]

        cat = argv[1].lower()
        try:
            category = Category[cat]
        except KeyError:
            print(f"Invalid category: {cat}", file=sys.stderr)
            return ExitCode.ArgError.value

        what = urllib.parse.quote(' '.join(argv[2:]))
        params = ((engine_class, what, category, e)
                  for e in engines if (engine_class := import_engine(e)) is not None)

        search_success = False
        if THREADED:
            processes = max(min(len(engines), MAX_THREADS), 1)
            with Pool(processes) as pool:
                pending = pool.map_async(run_search, params)
                try:
                    search_success = all(pending.get(timeout=deadline))
                except PoolTimeoutError:
                    # Rows are streamed directly by workers, so everything
                    # printed before the deadline remains usable.  Terminating
                    # the pool here also guarantees nova2 itself exits instead
                    # of leaving the Zig worker stuck waiting for EOF.
                    pool.terminate()
                    pool.join()
                    search_success = True
        else:
            search_success = all(map(run_search, params))

        return ExitCode.OK.value if search_success else ExitCode.AppError.value

    sys.exit(main())
