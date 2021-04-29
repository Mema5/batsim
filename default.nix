{ kapack ? import
    (fetchTarball "https://github.com/oar-team/nur-kapack/archive/master.tar.gz")
  {}
, doUnitTests ? true
, doCoverage ? true
, coverageCobertura ? false
, coverageCoveralls ? false
, coverageGcovTxt ? false
, coverageHtml ? false
, coverageSonarqube ? false
, werror ? false
, doValgrindAnalysis ? false
, debug ? true
, simgrid ? kapack.simgrid-light.override { inherit debug; }
, batsched ? kapack.batsched-master
, batexpe ? kapack.batexpe
, pybatsim ? kapack.pybatsim-master
# set this to avoid running tests over and over
# (e.g., to debug coverage reports or to run tests and coverage report separately)
, testVersion ? toString builtins.currentTime
}:

let
  pkgs = kapack.pkgs;
  pythonPackages = pkgs.python37Packages;
  buildPythonPackage = pythonPackages.buildPythonPackage;

  jobs = rec {
    inherit pkgs;
    inherit kapack;
    # Batsim executable binary file.
    batsim = (kapack.batsim.override { inherit debug simgrid; }).overrideAttrs (attr: rec {
      buildInputs = attr.buildInputs
        ++ pkgs.lib.optional doUnitTests [pkgs.gtest.dev];
      src = pkgs.lib.sourceByRegex ./. [
        "^src"
        "^src/.*\.?pp"
        "^src/unittest"
        "^src/unittest/.*\.?pp"
        "^meson\.build"
        "^meson_options\.txt"
      ];
      mesonFlags = [ "--warnlevel=3" ]
        ++ pkgs.lib.optional werror [ "--werror" ]
        ++ pkgs.lib.optional doUnitTests [ "-Ddo_unit_tests=true" ]
        ++ pkgs.lib.optional doCoverage [ "-Db_coverage=true" ];

      # Unit tests
      doCheck = doUnitTests;
      checkPhase = ''
        meson test --print-errorlogs
      '';

      # Keep files generated by GCOV, so depending jobs can use them.
      postInstall = pkgs.lib.optionalString doCoverage ''
        mkdir -p $out/gcno
        cp batsim.p/*.gcno $out/gcno/
        cp libbatlib.a.p/*.gcno $out/gcno/
      '' + pkgs.lib.optionalString (doCoverage && doUnitTests) ''
        mkdir -p $out/gcda
        cp libbatlib.a.p/*.gcda $out/gcda/
      '';
    });

    # Another Batsim. This one is built from cmake.
    batsim_cmake = batsim.overrideAttrs (attr: rec {
      buildInputs = attr.buildInputs ++ [pkgs.cmake];
      src = pkgs.lib.sourceByRegex ./. [
        "^src"
        "^src/.*\.?pp"
        "^CMakeLists.txt"
      ];
      configurePhase = ''
        mkdir build && cd build
        cmake .. -G Ninja -DCMAKE_INSTALL_PREFIX=$out
      '';
      buildPhase = "ninja";
      installPhase = "ninja install";
    });

    # Convenient development shell for qtcreator+cmake users.
    qtcreator_shell = pkgs.mkShell rec {
      name = "batsim-dev-shell-qtcreator-cmake";
      buildInputs = batsim.buildInputs ++
        [pkgs.cmake pkgs.qtcreator];
    };

    # Batsim integration tests.
    integration_tests = pkgs.stdenv.mkDerivation rec {
      pname = "batsim-integration-tests";
      version = testVersion;
      src = pkgs.lib.sourceByRegex ./. [
        "^test"
        "^test/.*\.py"
        "^platforms"
        "^platforms/.*\.xml"
        "^workloads"
        "^workloads/.*\.json"
        "^workloads/.*\.dax"
        "^workloads/smpi"
        "^workloads/smpi/.*"
        "^workloads/smpi/.*/.*\.txt"
        "^events"
        "^events/.*\.txt"
      ];
      buildInputs = with pkgs.python37Packages; [
        batsim batsched batexpe pkgs.redis
        pybatsim pytest pytest_html pandas] ++
      pkgs.lib.optional doValgrindAnalysis [ pkgs.valgrind ];

      pytestArgs = "-ra test/ --html=./report/pytest_report.html" +
        pkgs.lib.optionalString doValgrindAnalysis " --with-valgrind";

      preBuild = pkgs.lib.optionalString doCoverage ''
        mkdir -p gcda
        export GCOV_PREFIX=$(realpath gcda)
        export GCOV_PREFIX_STRIP=5
      '' + pkgs.lib.optionalString (doCoverage && doUnitTests) ''
        cp --no-preserve=all ${batsim}/gcda/*.gcda gcda/
      '';
      buildPhase = ''
        runHook preBuild
        set +e
        pytest ${pytestArgs}
        echo $? > ./pytest_returncode
        set -e
      '';

      checkPhase = ''
        pytest_return_code=$(cat ./pytest_returncode)
        echo "pytest return code: $pytest_return_code"
        if [ $pytest_return_code -ne 0 ] ; then
          exit 1
        fi
      '';
      doCheck = false;

      installPhase = ''
        mkdir -p $out
        mv ./report/* ./pytest_returncode $out/
      '' + pkgs.lib.optionalString doCoverage ''
        mv ./gcda $out/
      '';
    };

    # Generate coverage reports, from gcov traces in batsim and batsim_integration_tests.
    coverage-report = pkgs.stdenv.mkDerivation rec {
      pname = "batsim-coverage-report";
      version = integration_tests.version;

      buildInputs = batsim.buildInputs ++ [ kapack.gcovr ]
        ++ [ batsim integration_tests ];
      src = batsim.src;

      buildPhase = ''
        mkdir cov-merged
        cd cov-merged
        cp ${batsim}/gcno/* ${integration_tests}/gcda/* ./
        gcov -p *.gcno
        mkdir report
      '' + pkgs.lib.optionalString coverageHtml ''
        mkdir -p report/html
      '' + pkgs.lib.optionalString coverageGcovTxt ''
        mkdir -p report/gcov-txt
        cp \^\#src\#*.gcov report/gcov-txt/
      '' + ''
        gcovr -g -k -r .. --filter '\.\./src/' \
          --txt report/file-summary.txt \
          --csv report/file-summary.csv \
          --json-summary report/file-summary.json \
        '' + pkgs.lib.optionalString coverageCobertura ''
          --xml report/cobertura.xml \
        '' + pkgs.lib.optionalString coverageCoveralls ''
          --coveralls report/coveralls.json \
        '' + pkgs.lib.optionalString coverageHtml ''
          --html-details report/html/index.html \
        '' + pkgs.lib.optionalString coverageSonarqube ''
          --sonarqube report/sonarqube.xml \
        '' + ''
          --print-summary
      '';
      installPhase = ''
        mkdir -p $out
        cp -r report/* $out/
      '';
    };

    # Batsim doxygen documentation.
    doxydoc = pkgs.stdenv.mkDerivation rec {
      name = "batsim-doxygen-documentation";
      src = pkgs.lib.sourceByRegex ./. [
        "^src"
        "^src/.*\.?pp"
        "^doc"
        "^doc/Doxyfile"
        "^doc/doxygen_mainpage.md"
      ];
      buildInputs = [pkgs.doxygen];
      buildPhase = "(cd doc && doxygen)";
      installPhase = ''
        mkdir -p $out
        mv doc/doxygen_doc/html/* $out/
      '';
      checkPhase = ''
        nb_warnings=$(cat doc/doxygen_warnings.log | wc -l)
        if [[ $nb_warnings -gt 0 ]] ; then
          echo "FAILURE: There are doxygen warnings!"
          cat doc/doxygen_warnings.log
          exit 1
        fi
      '';
      doCheck = true;
    };

    # Batsim sphinx documentation.
    sphinx_doc = pkgs.stdenv.mkDerivation rec {
      name = "batsim-sphinx-documentation";

      src = pkgs.lib.sourceByRegex ./. [
        "^\.gitlab-ci\.yml"
        "^\.travis\.yml"
        "^default.nix"
        "^doc"
        "^doc/batsim_rjms_overview.png"
        "^docs"
        "^docs/conf.py"
        "^docs/Makefile"
        "^docs/.*\.bash"
        "^docs/.*\.rst"
        "^docs/img"
        "^docs/img/.*\.png"
        "^docs/img/ci"
        "^docs/img/ci/.*\.svg"
        "^docs/img/logo"
        "^docs/img/logo/logo.png"
        "^docs/img/ptask"
        "^docs/img/ptask/CommMatrix.svg"
        "^docs/img/proto"
        "^docs/img/proto/.*\.png"
        "^docs/tuto-app-model"
        "^docs/tuto-app-model/.*\.rst"
        "^docs/tuto-app-model/.*\.svg"
        "^docs/tuto-first-simulation"
        "^docs/tuto-first-simulation/.*\.bash"
        "^docs/tuto-first-simulation/.*\.rst"
        "^docs/tuto-first-simulation/.*\.out"
        "^docs/tuto-first-simulation/.*\.yaml"
        "^docs/tuto-first-simulation/.*\.nix"
        "^docs/tuto-reproducible-experiment"
        "^docs/tuto-reproducible-experiment/.*\.nix"
        "^docs/tuto-reproducible-experiment/.*\.rst"
        "^docs/tuto-reproducible-experiment/.*\.bash"
        "^docs/tuto-reproducible-experiment/.*\.R"
        "^docs/tuto-reproducible-experiment/.*\.Rmd"
        "^docs/tuto-result-analysis"
        "^docs/tuto-result-analysis/.*\.rst"
        "^docs/tuto-result-analysis/.*\.R"
        "^docs/tuto-sched-implem"
        "^docs/tuto-sched-implem/.*\.rst"
        "^env"
        "^env/docker"
        "^env/docker/Dockerfile"
        "^events"
        "^events/test_events_4hosts\.txt"
        "^workloads"
        "^workloads/test_various_profile_types\.json"
      ];
      buildInputs = with pythonPackages; [ sphinx sphinx_rtd_theme ];

      buildPhase = "cd docs && make html";
      installPhase = ''
        mkdir -p $out
        cp -r _build/html $out/
      '';
    };

    # Dependencies not in nixpkgs as I write these lines.
    pytest_metadata = buildPythonPackage {
      name = "pytest-metadata-1.8.0";
      doCheck = false;
      propagatedBuildInputs = [
        pythonPackages.pytest
        pythonPackages.setuptools_scm
      ];
      src = builtins.fetchurl {
        url = "https://files.pythonhosted.org/packages/12/38/eed3a1e00c765e4da61e4e833de41c3458cef5d18e819d09f0f160682993/pytest-metadata-1.8.0.tar.gz";
        sha256 = "1fk6icip2x1nh4kzhbc8cnqrs77avpqvj7ny3xadfh6yhn9aaw90";
      };
    };

    pytest_html = buildPythonPackage {
      name = "pytest-html-1.20.0";
      doCheck = false;
      propagatedBuildInputs = [
        pythonPackages.pytest
        pytest_metadata
      ];
      src = builtins.fetchurl {
        url = "https://files.pythonhosted.org/packages/08/3e/63d998f26c7846d3dac6da152d1b93db3670538c5e2fe18b88690c1f52a7/pytest-html-1.20.0.tar.gz";
        sha256 = "17jyn4czkihrs225nkpj0h113hc03y0cl07myb70jkaykpfmrim7";
      };
    };
  };
in
  jobs
