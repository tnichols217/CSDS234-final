{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = {...}@inputs:
  inputs.flake-utils.lib.eachDefaultSystem (system: let
    pkgs = (import inputs.nixpkgs) {
      inherit system;
      config = {
        allowUnfree = true;
      };
    };
    contextily = pkgs.python3Packages.buildPythonPackage rec {
      pname = "contextily";
      version = "1.7.0";
      src = pkgs.python3Packages.fetchPypi {
        inherit pname version;
        sha256 = "sha256-ZTT6pXAribRtDYG0xTh1Ty2LPdjMKYRUsRzO36Z+c6w=";
      };
      pyproject = true;
      build-system = [ pkgs.python3Packages.setuptools ];
      propagatedBuildInputs = with pkgs.python3Packages; [
        geopy
        joblib
        matplotlib
        mercantile
        numpy
        pillow
        rasterio
        requests
        xyzservices
        setuptools-scm
      ];
      doCheck = false; # Skip tests to save time
    };
    in
    {
      devShells = rec {
        docker-python = pkgs.mkShell {
          packages = with pkgs; [
            docker-compose
            docker
            podman-compose
            podman
            jupyter
            gdal
            qgis
            postgresql16Packages.postgis
            (python3.withPackages (pythonPackages: with pythonPackages; [
              ipykernel
              pandas
              geopandas
              scikit-learn
              pip
              numpy
              scipy
              matplotlib
              notebook
              requests
              python-dotenv
              psycopg2
              psycopg
              folium
              mapclassify
              contextily
            ]))
          ];
        };
        default = docker-python;
      };
      apps = rec {
          db = {
            type = "app";
            program = "${pkgs.writeShellScriptBin "start-compose.sh" ''GDK_BACKEND=x11 ${pkgs.dbeaver-bin}/bin/dbeaver''}/bin/start-compose.sh";
          };
          default = db;
        # pgadmin = {
        #   type = "app";
        #   program = "${pkgs.pgadmin4-desktopmode}/bin/pgadmin4";
        # };
        # default = pgadmin;
      };
    }
  );
}