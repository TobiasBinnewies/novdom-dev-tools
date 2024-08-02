import filepath
import gleam/dict.{type Dict}

import gleam/list
import gleam/result
import gleam/string
import glint.{type Command}
import lustre_dev_tools/cli.{type Cli}
import lustre_dev_tools/cmd
import lustre_dev_tools/error.{
  type Error, CannotWriteFile, DependencyInstallationError,
}
import lustre_dev_tools/project.{type PackageJson}
import simplifile

pub fn command() -> Command(Nil) {
  let description = "Installing JavaScript dependencies"

  use <- glint.command_help(description)
  use <- glint.unnamed_args(glint.EqArgs(0))
  use _, _, flags <- glint.command()

  case cli.run(install(), flags) {
    Ok(_) -> Nil
    Error(error) -> error.explain(error)
  }
}

pub fn install() -> Cli(Nil) {
  use <- cli.log("Installing JavaScript dependencies")

  let root = project.root()

  let dependencies = ["quill", "tailwind-merge"]
  let dev_dependencies = ["jsdom"]

  case project.package_json() {
    Ok(package_json) -> {
      // check if all dependencies are already installed
      let has_dependencies =
        check_if_all_dependencies_installed(
          package_json.dependencies,
          dependencies,
        )
      let has_dev_dependencies =
        check_if_all_dependencies_installed(
          package_json.dev_dependencies,
          dev_dependencies,
        )
      case has_dependencies && has_dev_dependencies {
        True -> {
          use <- cli.success("All dependencies already installed!")
          cli.return(Nil)
        }
        False -> do_install(root, dependencies, dev_dependencies)
      }
    }
    Error(_) -> do_install(root, dependencies, dev_dependencies)
  }
}

fn check_if_all_dependencies_installed(
  installed: Dict(String, String),
  needed: List(String),
) {
  use dep <- list.all(needed)
  dict.has_key(installed, dep)
}

fn do_install(root, dependencies, dev_dependencies) -> Cli(Nil) {
  let install_dev_result =
    cmd.exec(run: "bun", in: root, with: [
      "install",
      "--dev",
      ..dev_dependencies
    ])
    |> result.map_error(fn(pair) { DependencyInstallationError(pair.1, "bun") })
  use _ <- cli.try(install_dev_result)

  let install_result =
    cmd.exec(run: "bun", in: root, with: ["install", ..dependencies])
    |> result.map_error(fn(pair) { DependencyInstallationError(pair.1, "bun") })
  use _ <- cli.try(install_result)

  use <- cli.success("Dependencies installed!")

  cli.return(Nil)
}
