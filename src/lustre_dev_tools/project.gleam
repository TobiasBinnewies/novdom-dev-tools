// IMPORTS ---------------------------------------------------------------------

import filepath
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type DecodeError, type Decoder, type Dynamic, DecodeError}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/package_interface.{type Type, Fn, Named, Tuple, Variable}
import gleam/pair
import gleam/regex.{type Match, Match}
import gleam/result
import gleam/set
import gleam/string
import lustre_dev_tools/cmd
import lustre_dev_tools/error.{type Error, BuildError}
import simplifile
import tom.{type Toml}

// CONFIG ----------------------------------------------------------------------

pub const needed_node_modules = ["quill", "tailwind-merge"]

pub const needed_dev_node_modules = ["jsdom"]

// TYPES -----------------------------------------------------------------------

pub type Config {
  Config(name: String, version: String, toml: Dict(String, Toml))
}

pub type Interface {
  Interface(name: String, version: String, modules: Dict(String, Module))
}

pub type Module {
  Module(constants: Dict(String, Type), functions: Dict(String, Function))
}

pub type Function {
  Function(parameters: List(Type), return: Type)
}

pub type PackageJson {
  PackageJson(
    dependencies: Option(Dict(String, String)),
    dev_dependencies: Option(Dict(String, String)),
  )
}

// COMMANDS --------------------------------------------------------------------

pub fn otp_version() -> Int {
  let version = do_otp_version()
  case int.parse(version) {
    Ok(version) -> version
    Error(_) -> panic as { "unexpected version number format: " <> version }
  }
}

@external(erlang, "lustre_dev_tools_ffi", "otp_version")
fn do_otp_version() -> String

/// Compile the current project running the `gleam build` command.
///
pub fn build() -> Result(Nil, Error) {
  cmd.exec(run: "gleam", in: ".", with: ["build", "--target", "javascript"])
  |> result.map_error(fn(err) { BuildError(pair.second(err)) })
  |> result.replace(Nil)
}

pub fn interface() -> Result(Interface, Error) {
  use Config(name, ..) <- result.try(config())

  // Gleam currently has a bug with the `export package-interface` command that
  // means cached modules are not emitted. This is, obviously, a problem if a
  // you try and export the interface multiple times (which happens regularly
  // for us).
  //
  // We clear build files for *just* the user's application (because we don't
  // actually care about the dependencies) before running the export command.
  // This forces Gleam to recompile them and properly emit the interface.
  //
  let caches = [
    "build/prod/javascript", "build/prod/erlang", "build/dev/javascript",
    "build/dev/erlang",
  ]

  list.each(caches, fn(cache) {
    filepath.join(root(), cache)
    |> filepath.join(name)
    |> simplifile.delete
  })

  let dir = filepath.join(root(), "build/.lustre")
  let out = filepath.join(dir, "package-interface.json")
  let args = ["export", "package-interface", "--out", out]

  cmd.exec(run: "gleam", in: ".", with: args)
  |> result.map_error(fn(err) { BuildError(pair.second(err)) })
  |> result.then(fn(_) {
    let assert Ok(json) = simplifile.read(out)
    let assert Ok(interface) = json.decode(json, interface_decoder)

    Ok(interface)
  })
}

/// Read the project configuration in the `gleam.toml` file.
///
pub fn config() -> Result(Config, Error) {
  // Since we made sure that the project could compile we're sure that there is
  // bound to be a `gleam.toml` file somewhere in the current directory (or in
  // its parent directories). So we can safely call `root()` without
  // it looping indefinitely.
  let configuration_path = filepath.join(root(), "gleam.toml")

  // All these operations are safe to assert because the Gleam project wouldn't
  // compile if any of this stuff was invalid.
  let assert Ok(configuration) = simplifile.read(configuration_path)
  let assert Ok(toml) = tom.parse(configuration)
  let assert Ok(name) = tom.get_string(toml, ["name"])
  let assert Ok(version) = tom.get_string(toml, ["version"])

  Ok(Config(name: name, version: version, toml: toml))
}

pub fn all_node_modules_installed() -> Bool {
  case package_json() {
    Error(_) -> {
      False
    }
    Ok(package_json) -> {
      let dependencies = package_json.dependencies
      let dev_dependencies = package_json.dev_dependencies

      let has_dependencies =
        check_if_all_packages_installed(dependencies, needed_node_modules)
      let has_dev_dependencies =
        check_if_all_packages_installed(
          dev_dependencies,
          needed_dev_node_modules,
        )

      has_dependencies && has_dev_dependencies
    }
  }
}

fn check_if_all_packages_installed(
  installed: Option(Dict(String, String)),
  needed: List(String),
) {
  let root = root()
  let modules = filepath.join(root, "node_modules")
  case installed {
    None -> False
    Some(installed) ->
      list.all(needed, fn(dep) {
        case dict.has_key(installed, dep) {
          True -> {
            let module = filepath.join(modules, dep)
            case simplifile.is_directory(module) {
              Ok(True) -> True
              Ok(False) | Error(_) -> False
            }
          }
          False -> False
        }
      })
  }
}

pub fn package_json() -> Result(PackageJson, simplifile.FileError) {
  use json <- result.try(simplifile.read("package.json"))

  let assert Ok(package_json) = json.decode(json, package_json_decoder)

  Ok(package_json)
}

// UTILS -----------------------------------------------------------------------

/// Finds the path leading to the project's root folder. This recursively walks
/// up from the current directory until it finds a `gleam.toml`.
///
pub fn root() -> String {
  find_root(".")
}

fn find_root(path: String) -> String {
  let toml = filepath.join(path, "gleam.toml")

  case simplifile.is_file(toml) {
    Ok(False) | Error(_) -> find_root(filepath.join("..", path))
    Ok(True) -> path
  }
}

pub fn build_dir(is_prod: Bool) -> String {
  case is_prod {
    True -> filepath.join(root(), "dist")
    False -> filepath.join(root(), "build/dev/static")
  }
}

pub fn type_to_string(type_: Type) -> String {
  case type_ {
    Tuple(elements) -> {
      let elements = list.map(elements, type_to_string)
      "#(" <> string.join(elements, with: ", ") <> ")"
    }

    Fn(params, return) -> {
      let params = list.map(params, type_to_string)
      let return = type_to_string(return)
      "fn(" <> string.join(params, with: ", ") <> ") -> " <> return
    }

    Named(name, _package, _module, []) -> name
    Named(name, _package, _module, params) -> {
      let params = list.map(params, type_to_string)
      name <> "(" <> string.join(params, with: ", ") <> ")"
    }

    Variable(id) -> "a_" <> int.to_string(id)
  }
}

pub fn all_node_modules() -> List(String) {
  let src_dir = filepath.join(root(), "build/dev/javascript")
  let assert Ok(files) = simplifile.get_files(src_dir)
  {
    use modules, file <- list.fold(files, set.new())
    use <- bool.guard(!is_js(file), modules)
    let assert Ok(src) = simplifile.read(file)
    used_node_modules(src)
    |> set.from_list
    |> set.union(modules)
  }
  |> set.to_list
}

fn is_js(file: String) -> Bool {
  case file |> filepath.extension |> result.unwrap("") {
    "js" | "mjs" | "ts" ->
      !{ file |> filepath.base_name |> string.contains("test") }
    _ -> False
  }
}

pub fn replace_node_modules_with_relative_path(src: String) -> String {
  let modules = node_modules_matches(src)

  let replacements = {
    use module <- list.map(modules)

    let assert Match(full, [Some(name)]) = module
    let replacement = string.replace(full, name, "/modules/" <> name <> ".mjs")
    #(name, replacement)
  }

  use src, replacement <- list.fold(replacements, src)

  let assert Ok(to_replace) =
    regex.from_string(
      "(?:from|import) (?:\"|')(" <> replacement.0 <> ")(?:\"|')",
    )
  regex.replace(to_replace, src, replacement.1)
}

fn used_node_modules(src: String) -> List(String) {
  let modules = node_modules_matches(src)

  use module <- list.map(modules)

  let assert Match(_, [Some(name)]) = module
  name
}

fn node_modules_matches(src: String) -> List(Match) {
  let assert Ok(modules) =
    regex.from_string("(?:from|import) (?:\"|')([\\w|-]*)(?:\"|')")
  regex.scan(modules, src)
}

// DECODERS --------------------------------------------------------------------

fn interface_decoder(dyn: Dynamic) -> Result(Interface, List(DecodeError)) {
  dynamic.decode3(
    Interface,
    dynamic.field("name", dynamic.string),
    dynamic.field("version", dynamic.string),
    dynamic.field("modules", string_dict(module_decoder)),
  )(dyn)
}

fn module_decoder(dyn: Dynamic) -> Result(Module, List(DecodeError)) {
  dynamic.decode2(
    Module,
    dynamic.field(
      "constants",
      string_dict(dynamic.field("type", package_interface.type_decoder)),
    ),
    dynamic.field("functions", string_dict(function_decoder)),
  )(dyn)
}

fn function_decoder(dyn: Dynamic) -> Result(Function, List(DecodeError)) {
  dynamic.decode2(
    Function,
    dynamic.field("parameters", dynamic.list(labelled_argument_decoder)),
    dynamic.field("return", package_interface.type_decoder),
  )(dyn)
}

fn labelled_argument_decoder(dyn: Dynamic) -> Result(Type, List(DecodeError)) {
  // In this case we don't really care about the label, so we're just ignoring
  // it and returning the argument's type.
  dynamic.field("type", package_interface.type_decoder)(dyn)
}

fn string_dict(values: Decoder(a)) -> Decoder(Dict(String, a)) {
  dynamic.dict(dynamic.string, values)
}

fn package_json_decoder(dyn: Dynamic) -> Result(PackageJson, List(DecodeError)) {
  dynamic.decode2(
    PackageJson,
    dynamic.optional_field("dependencies", string_dict(dynamic.string)),
    dynamic.optional_field("devDependencies", string_dict(dynamic.string)),
  )(dyn)
}
