import 'dart:async';
import 'dart:convert';

import 'package:code_builder/code_builder.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart';
import 'package:web3dart/contracts.dart';
import 'package:web3dart/src/utils/abi_parser.dart';

class ContractGenerator implements Builder {
  var index = 0;

  @override
  Map<String, List<String>> get buildExtensions => const {
        '.abi.json': ['.g.dart']
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;
    final withoutExtension =
        inputId.path.substring(0, inputId.path.length - '.abi.json'.length);

    var abiCode = await buildStep.readAsString(inputId);
    // Remove unnecessary whitespace
    abiCode = json.encode(json.decode(abiCode));
    final abi = ContractAbi.fromJson(abiCode, _suggestName(withoutExtension));

    final outputId = AssetId(inputId.package, '$withoutExtension.g.dart');
    await buildStep.writeAsString(outputId, _parseAbi(abi, abiCode));
  }

  String _suggestName(String pathWithoutExtension) {
    final base = basename(pathWithoutExtension);
    return base[0].toUpperCase() + base.substring(1);
  }

  //main method that parses abi to dart code
  String _parseAbi(ContractAbi abi, String abiCode) {
    final library = Library((b) {
      b.directives.addAll([Directive.import('package:web3dart/web3dart.dart')]);
      b.body.addAll([
        Class((b) => b
          ..name = abi.name
          ..fields.addAll(_classFields)
          ..methods.addAll(_getMethods(abi.functions))
          ..constructors.add(Constructor((b) => b
            ..initializers.add(argContract
                .assign(funDeployedContract.call([
                  funContractABI
                      .call([literalString(abiCode), literalString(abi.name)]),
                  argContractAddress
                ]))
                .code)
            ..requiredParameters.addAll(_requiredConstructorParams)
            ..optionalParameters.addAll(_optionalConstructorParams)))),
      ]);
      b.body.addAll(_customClasses(abi.functions));
    });

    final emitter = DartEmitter();
    return DartFormatter().format('${library.accept(emitter)}');
  }

  // Create custom classes to encapsulate response for functions that return multiple values
  List<Class> _customClasses(List<ContractFunction> functions) {
    final customClasses = <Class>[];
    for (final function in functions) {
      if (function.outputs.length > 1) {
        function.outputs.asMap()

        final fields = function.outputs.map((out) => Field((b) => b
          ..name = out.name.isEmpty?'':out.name
          ..modifier = FieldModifier.final$
          ..type = out.type.name.toDart()));

        final params = function.outputs.map((out) => Parameter((b) => b
          ..name = out.name.isEmpty?'':out.name
          ..type = out.type.name.toDart()));

        customClasses.add(Class((b) => b
          ..name = _customClassName(function.name)
          ..constructors.add(Constructor((b) => b
            ..requiredParameters.addAll(params)))
          ..fields.addAll(fields)));
        index++;
      }

    }
    return customClasses;
  }

  List<Method> _getMethods(List<ContractFunction> functions) {
    final methods = <Method>[];
    for (final function in functions) {
      if (!function.isConstructor) {
        methods.add(Method((b) => b
          ..modifier = MethodModifier.async
          ..returns = _returnStatement(function)
          ..name = function.name
          ..body = function.isConstant
              ? _constantBody(function)
              : _notConstantBody(function)
          ..requiredParameters.addAll(_getParameters(function))));
      }
    }
    methods.addAll(readAndWriteMethods);

    return methods;
  }

  List<Parameter> _getParameters(ContractFunction function) {
    final parameters = <Parameter>[];
    for (final param in function.parameters) {
      parameters.add(Parameter((b) => b
        ..name = param.name
        ..type = param.type.name.toDart()));
    }
    return parameters;
  }

  Code _constantBody(ContractFunction function) {
    final params = function.parameters.map((e) => e.name).toList();
    final returnParams = function.outputs.map((e) => Parameter((b) => b));
    return Block((b) => b
      ..addExpression(
          CodeExpression(funFunction.call([literalString(function.name)]).code)
              .assignFinal('function'))
      ..addExpression(
          CodeExpression(Code('[${params.join(', ')}]')).assignFinal('params'))
      ..addExpression(funConstantReturn));
  }

  Code _notConstantBody(ContractFunction function) {
    final params = function.parameters.map((e) => e.name).toList();

    return Block((b) => b
      ..addExpression(funFunction
          .call([literalString(function.name)]).assignFinal('function'))
      ..addExpression(
          CodeExpression(Code('[${params.join(', ')}]')).assignFinal('params'))
      ..addExpression(funCredentialsFromPrivateKey
          .call([argPrivateKey]).assignFinal('credentials'))
      ..addExpression(funCallContract
          .call([nArgContract, nArgFunction, nArgParameters]).assignFinal(
              'transaction'))
      ..addExpression(funWrite));
  }
}

Reference _returnStatement(ContractFunction function) {
  if (!function.isConstant) {
    return futurize(string);
  } else if (function.outputs.isEmpty) {
    return futurize(refer('void'));
  } else if (function.outputs.length > 1) {
    return futurize(refer(_customClassName(function.name)));
  } else {
    return futurize(function.outputs[0].type.name.toDart());
  }
}

Reference _constantFunctionReturn() {}

final _classFields = [
  Field((b) => b
    ..name = 'contractAddress'
    ..type = ethereumAddress
    ..modifier = FieldModifier.final$),
  Field((b) => b
    ..name = 'client'
    ..type = web3Client
    ..modifier = FieldModifier.final$),
  Field((b) => b
    ..name = 'contract'
    ..type = deployedContract
    ..modifier = FieldModifier.final$),
  Field((b) => b
    ..name = 'privateKey'
    ..type = string
    ..modifier = FieldModifier.final$),
  Field((b) => b
    ..name = 'chainId'
    ..type = dartInt
    ..modifier = FieldModifier.final$)
];

final _requiredConstructorParams = [
  Parameter((b) => b
    ..name = 'contractAddress'
    ..named = true
    ..toThis = true),
  Parameter((b) => b
    ..name = 'client'
    ..named = true
    ..toThis = true),
  Parameter((b) => b
    ..name = 'privateKey'
    ..named = true
    ..toThis = true),
];

final _optionalConstructorParams = [
  Parameter((b) => b
    ..name = 'chainId'
    ..required = false
    ..named = true
    ..toThis = true
    ..defaultTo = const Code('1'))
];

String _customClassName(String functionName) =>
    '${functionName[0].toUpperCase()}${functionName.substring(1)}Response';
