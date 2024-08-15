// IMPORTS ---------------------------------------------------------------------

import filepath
import gleam/bool
import gleam/dict
import gleam/package_interface.{type Type, Named, Variable}
import gleam/result
import gleam/string
import glint.{type Command}
import lustre_dev_tools/cli.{type Cli, do, try}
import lustre_dev_tools/cli/flag
import lustre_dev_tools/cmd
import lustre_dev_tools/error.{
  type Error, BundleError, CannotWriteFile, MainMissing, ModuleMissing,
}
import lustre_dev_tools/esbuild
import lustre_dev_tools/project.{type Module}
import lustre_dev_tools/tailwind
import simplifile

// DESCRIPTION -----------------------------------------------------------------
pub const description: String = "
Commands to build different kinds of Lustre application. These commands go beyond
just running `gleam build` and handle features like bundling, minification, and
integration with other build tools.
"

// COMMANDS --------------------------------------------------------------------

pub fn app() -> Command(Nil) {
  let description =
    "
Build and bundle an entire Lustre application. The generated JavaScript module
calls your app's `main` function on page load and can be included in any Web
page without Gleam or Lustre being present.


This is different from using `gleam build` directly because it produces a single
JavaScript module for you to host or distribute.
"
  use <- glint.command_help(description)
  use <- glint.unnamed_args(glint.EqArgs(0))
  use is_prod <- glint.flag(flag.prod())
  use detect_tailwind <- glint.flag(flag.detect_tailwind())
  use _tailwind_entry <- glint.flag(flag.tailwind_entry())
  use _outdir <- glint.flag(flag.outdir())
  use _ext <- glint.flag(flag.ext())
  use _, _, flags <- glint.command()
  let script = {
    use is_prod <- do(cli.get_bool("prod", False, ["build"], is_prod))
    use detect_tailwind <- do(cli.get_bool(
      "detect-tailwind",
      True,
      ["build"],
      detect_tailwind,
    ))

    do_app(is_prod, detect_tailwind)
  }

  case cli.run(script, flags) {
    Ok(_) -> Nil
    Error(error) -> error.explain(error)
  }
}

pub fn do_app(is_prod: Bool, detect_tailwind: Bool) -> Cli(Nil) {
  use <- cli.log("Building your project")
  use project_name <- do(cli.get_name())

  use <- cli.success("Project compiled successfully")
  use <- cli.log("Checking if I can bundle your application")
  use module <- try(get_module_interface(project_name))
  use _ <- try(check_main_function(project_name, module))

  use <- cli.log("Creating the bundle entry file")
  let root = project.root()
  let tempdir = filepath.join(root, "build/.lustre")
  let default_outdir = project.build_dir(is_prod)
  use outdir <- cli.do(
    cli.get_string(
      "outdir",
      default_outdir,
      ["build"],
      glint.get_flag(_, flag.outdir()),
    ),
  )
  let _ = simplifile.create_directory_all(tempdir)
  let _ = simplifile.create_directory_all(outdir)

  use _ <- do(prepare_html(outdir, is_prod))

  use template <- cli.template("entry-with-main.mjs")
  let entry = string.replace(template, "{app_name}", project_name)

  let entryfile = filepath.join(tempdir, "entry.mjs")
  use ext <- cli.do(
    cli.get_string("ext", "mjs", ["build"], glint.get_flag(_, flag.ext())),
  )
  let ext = case is_prod {
    True -> ".min." <> ext
    False -> "." <> ext
  }

  let outfile =
    project_name
    |> string.append(ext)
    |> filepath.join(outdir, _)

  let assert Ok(_) = simplifile.write(entryfile, entry)
  use _ <- do(bundle(entry, tempdir, outfile, is_prod))
  use <- bool.guard(!detect_tailwind, cli.return(Nil))

  use entry <- cli.template("entry.css")
  let outfile =
    filepath.strip_extension(outfile)
    |> string.append(".css")

  use _ <- do(bundle_tailwind(entry, tempdir, outfile, is_prod))

  cli.return(Nil)
}

// STEPS -----------------------------------------------------------------------

fn get_module_interface(module_path: String) -> Result(Module, Error) {
  project.interface()
  |> result.then(fn(interface) {
    dict.get(interface.modules, module_path)
    |> result.replace_error(ModuleMissing(module_path))
  })
}

fn check_main_function(
  module_path: String,
  module: Module,
) -> Result(Nil, Error) {
  case dict.has_key(module.functions, "main") {
    True -> Ok(Nil)
    False -> Error(MainMissing(module_path))
  }
}

fn prepare_html(dir: String, is_prod: Bool) -> Cli(Nil) {
  let index = filepath.join(dir, "index.html")

  case simplifile.is_file(index) {
    Ok(True) -> cli.return(Nil)
    Ok(False) | Error(_) -> {
      use html <- cli.template("index.html")
      use app_name <- do(cli.get_name())
      let app_name = case is_prod {
        True -> app_name <> ".min"
        False -> app_name
      }
      let html = string.replace(html, "{app_name}", app_name)
      use _ <- try(write_html(index, html))

      cli.return(Nil)
    }
  }
}

fn write_html(path: String, source: String) -> Result(Nil, Error) {
  simplifile.write(path, source)
  |> result.map_error(CannotWriteFile(_, path))
}

fn bundle(
  entry: String,
  tempdir: String,
  outfile: String,
  is_prod: Bool,
) -> Cli(Nil) {
  let entryfile = filepath.join(tempdir, "entry.mjs")
  let assert Ok(_) = simplifile.write(entryfile, entry)

  use _ <- cli.try(project.build())

  case is_prod {
    True -> {
      use _ <- do(esbuild.bundle(entryfile, outfile, True))
      cli.return(Nil)
    }
    False -> {
      let entry = string.replace(entry, "/dev", "")
      let assert Ok(_) = simplifile.write(outfile, entry)
      let used_node_modules = project.all_node_modules()
      use _ <- cli.do(esbuild.bundle_node_modules(
        used_node_modules,
        project.build_dir(False),
      ))
      use <- cli.success("Bundle produced at `" <> outfile <> "`")
      cli.return(Nil)
    }
  }
}

fn bundle_tailwind(
  entry: String,
  tempdir: String,
  outfile: String,
  is_prod: Bool,
) -> Cli(Nil) {
  // We first check if there's a `tailwind.config.js` at the project's root.
  // If not present we do nothing; otherwise we go on with bundling.
  let root = project.root()
  let tailwind_config_file = filepath.join(root, "tailwind.config.js")
  let has_tailwind_config =
    simplifile.is_file(tailwind_config_file)
    |> result.unwrap(False)
  use <- bool.guard(when: !has_tailwind_config, return: cli.return(Nil))

  use _ <- do(tailwind.setup(get_os(), get_cpu()))

  use <- cli.log("Bundling with Tailwind")
  let default_entryfile = filepath.join(tempdir, "entry.css")
  use entryfile <- cli.do(
    cli.get_string(
      "tailwind-entry",
      default_entryfile,
      ["build"],
      glint.get_flag(_, flag.tailwind_entry()),
    ),
  )

  let assert Ok(_) = case entryfile == default_entryfile {
    True -> simplifile.write(entryfile, entry)
    False -> Ok(Nil)
  }

  let flags = ["--input=" <> entryfile, "--output=" <> outfile]
  let options = case is_prod {
    True -> ["--minify", ..flags]
    False -> flags
  }
  use _ <- try(exec_tailwind(root, options))
  use <- cli.success("Bundle produced at `" <> outfile <> "`")

  cli.return(Nil)
}

fn exec_tailwind(root: String, options: List(String)) -> Result(String, Error) {
  cmd.exec("./build/.lustre/bin/tailwind", in: root, with: options)
  |> result.map_error(fn(pair) { BundleError(pair.1) })
}

// UTILS -----------------------------------------------------------------------

fn is_string_type(t: Type) -> Bool {
  case t {
    Named(name: "String", package: "", module: "gleam", parameters: []) -> True
    _ -> False
  }
}

fn is_nil_type(t: Type) -> Bool {
  case t {
    Named(name: "Nil", package: "", module: "gleam", parameters: []) -> True
    _ -> False
  }
}

fn is_type_variable(t: Type) -> Bool {
  case t {
    Variable(..) -> True
    _ -> False
  }
}

fn is_compatible_app_type(t: Type) -> Bool {
  case t {
    Named(
      name: "App",
      package: "lustre",
      module: "lustre",
      parameters: [flags, ..],
    ) -> is_nil_type(flags) || is_type_variable(flags)
    _ -> False
  }
}

/// Turns a Gleam identifier into a name that can be imported in an mjs module
/// from Gleam's generated code.
///
fn importable_name(identifier: String) -> String {
  case is_reserved_keyword(identifier) {
    True -> identifier <> "$"
    False -> identifier
  }
}

fn is_reserved_keyword(name: String) -> Bool {
  // This list is taken directly from Gleam's compiler: there's some identifiers
  // that are not technically keywords (like `then`) but Gleam will still append
  // a "$" to those.
  case name {
    "await"
    | "arguments"
    | "break"
    | "case"
    | "catch"
    | "class"
    | "const"
    | "continue"
    | "debugger"
    | "default"
    | "delete"
    | "do"
    | "else"
    | "enum"
    | "export"
    | "extends"
    | "eval"
    | "false"
    | "finally"
    | "for"
    | "function"
    | "if"
    | "implements"
    | "import"
    | "in"
    | "instanceof"
    | "interface"
    | "let"
    | "new"
    | "null"
    | "package"
    | "private"
    | "protected"
    | "public"
    | "return"
    | "static"
    | "super"
    | "switch"
    | "this"
    | "throw"
    | "true"
    | "try"
    | "typeof"
    | "var"
    | "void"
    | "while"
    | "with"
    | "yield"
    | "undefined"
    | "then" -> True
    _ -> False
  }
}

// EXTERNALS -------------------------------------------------------------------

@external(erlang, "lustre_dev_tools_ffi", "get_os")
fn get_os() -> String

@external(erlang, "lustre_dev_tools_ffi", "get_cpu")
fn get_cpu() -> String
