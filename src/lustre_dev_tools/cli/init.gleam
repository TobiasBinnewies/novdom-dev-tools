import gleam/result
import glint.{type Command}
import lustre_dev_tools/cli.{type Cli}
import lustre_dev_tools/cli/flag
import lustre_dev_tools/cmd
import lustre_dev_tools/error.{
  type Error, DependencyInstallationError,
}
import lustre_dev_tools/project.{needed_dev_node_modules, needed_node_modules}

pub fn command() -> Command(Nil) {
  let description = "Installing JavaScript dependencies & adding tailwind"

  use <- glint.command_help(description)
  use <- glint.unnamed_args(glint.EqArgs(0))
  use pm <- glint.flag(flag.package_manager())
  use _, _, flags <- glint.command()

  let script = {
    use pm <- cli.do(cli.get_string("package-manager", "bun", ["init"], pm))

    init(pm)
  }

  case cli.run(script, flags) {
    Ok(_) -> Nil
    Error(error) -> error.explain(error)
  }
}

pub fn init(pm: String) -> Cli(Nil) {
  use <- cli.log("Installing JavaScript dependencies")

  let root = project.root()

  case project.all_node_modules_installed() {
    True -> {
      use <- cli.success("All dependencies already installed!")
      cli.return(Nil)
    }
    False -> do_install(pm, root, needed_node_modules, needed_dev_node_modules)
  }
}

fn do_install(pm, root, dependencies, dev_dependencies) -> Cli(Nil) {
  let install_dev_result =
    cmd.exec(run: pm, in: root, with: [
      install_command(pm),
      dev_flag(pm),
      ..dev_dependencies
    ])
    |> result.map_error(fn(pair) { DependencyInstallationError(pair.1, pm) })
  use _ <- cli.try(install_dev_result)

  let install_result =
    cmd.exec(run: pm, in: root, with: [install_command(pm), ..dependencies])
    |> result.map_error(fn(pair) { DependencyInstallationError(pair.1, pm) })
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
