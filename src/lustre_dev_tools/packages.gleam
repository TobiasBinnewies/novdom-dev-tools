import gleam/result
import lustre_dev_tools/cli.{type Cli}
import lustre_dev_tools/cmd
import lustre_dev_tools/error.{PackageInstallationError}
import lustre_dev_tools/project.{needed_dev_node_modules, needed_node_modules}

pub fn install(pm: String) -> Cli(Nil) {
  use <- cli.log("Installing JavaScript packages")

  let root = project.root()

  case project.all_node_modules_installed() {
    True -> {
      use <- cli.success("All packages already installed!")
      cli.return(Nil)
    }
    False -> do_install(pm, root, needed_node_modules, needed_dev_node_modules)
  }
}

fn do_install(
  pm: String,
  root: String,
  dependencies: List(String),
  dev_dependencies: List(String),
) -> Cli(Nil) {
  let install_dev_result =
    cmd.exec(run: pm, in: root, with: [
      install_command(pm),
      dev_flag(pm),
      ..dev_dependencies
    ])
    |> result.map_error(fn(pair) { PackageInstallationError(pair.1, pm) })
  use _ <- cli.try(install_dev_result)

  let install_result =
    cmd.exec(run: pm, in: root, with: [install_command(pm), ..dependencies])
    |> result.map_error(fn(pair) { PackageInstallationError(pair.1, pm) })
  use _ <- cli.try(install_result)

  use <- cli.success("Dependencies installed!")

  cli.return(Nil)
}

fn dev_flag(pm) -> String {
  case pm {
    "yarn" | "bun" -> "--dev"
    _ -> "--save-dev"
  }
}

fn install_command(pm) -> String {
  case pm {
    "yarn" -> "add"
    _ -> "install"
  }
}
