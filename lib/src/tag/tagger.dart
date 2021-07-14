// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// # Package Classification
///
/// ## Dart Platform Detection
///
/// A package is tagged "sdk:dart" if the package dependency graph
///
/// * does not have any SDK constraints beyond `dart`.
/// * the primary library does not transitively import "dart:ui" when the
///   environment constant "dart.library.ui" is unset.
///
/// The **primary library** is the library with the same name as the package.
/// If there is no such library we analyse
///
/// If a package is tagged "sdk:dart" it may also be tagged by any of the
/// following runtime tags (corresponding to
/// https://dart.dev/guides/libraries):
///
/// * runtime:native-jit
///
///   Can be run with the dart vm in jit mode. (Can use dart:io and
///   dart:mirrors)
///
/// * runtime:native-aot
///   Can be aot compiled with eg. dart2native (Can use dart:io but not
///   dart:mirrors)
///
/// * runtime:web
///   Can be compiled with DDC and dart2js. (Can use dart:html and friends, not
///   dart:io, dart:mirrors, dart:ffi, etc.)
///
/// A package has the same runtime tags as the primary library.
///
/// ### Classification as "runtime:native-jit"
///
/// A library with tag sdk:dart is tagged runtime:native-jit, if when the
/// environment constants are:
///
/// * dart.library.io = 'true'
/// * dart.library.js = 'false' ...
///
/// it holds that:
///
/// * The library is not "dart:js", "dart:html", or friends;
/// * The library does not transitively import a library which does not have the
///   tag runtime:native-jit.
///   (other runtime tags are derived similarly).
///
/// ## Flutter Platform Detection
///
/// A package is tagged "sdk:flutter" if:
///
/// * the package dependency graph does not have any SDK constraints beyond
///   `dart` and `flutter`; and;
/// * the primary library does not transitively import "dart:mirrors" when the
///   environment constant "dart.library.mirrors = false" is set.
///
/// If a package is tagged "sdk:flutter" it may also be tagged by any of the
/// following platform tags (corresponding to the target platforms supported by
/// Flutter).
///
/// * platform:android
/// * platform:ios
/// * platform:web
/// * platform:windows
/// * platform:linux
/// * platform:macos
/// * platform:web
///
/// A package has the same platform tags as the primary library.

import 'dart:io';

import 'package:analyzer/dart/analysis/context_builder.dart';
import 'package:analyzer/dart/analysis/context_locator.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

import '../null_safety.dart';
import '../pubspec_io.dart' show pubspecFromDir;
import '../utils.dart' show dartFilesFromLib;
import '_common.dart';
import '_graphs.dart';
import '_specs.dart';
import '_violations.dart';

export '_common.dart' show Explanation;
export '_specs.dart' show Runtime;

/// Calculates the tags for the package residing in a given directory.
class Tagger {
  final String packageName;
  final AnalysisSession _session;
  final PubspecCache _pubspecCache;
  final bool _isBinaryOnly;

  /// All libraries in `lib/` except those in `lib/src/`.
  final List<Uri> _publicLibraries;

  /// This is:
  ///  * `lib/<packageName>.dart`, if it exists,
  ///  * _publicLibraries, if no _primaryLibrary exists,
  ///  * all libraries, if no _publicLibraries exists.
  ///
  /// TODO(jonasfj): We should be using `lib/<packageName>.dart` (with fallback
  ///     to [_publicLibraries]) most places instead, and remove this property.
  ///     If a package has no public libraries, then we should perhaps avoid
  ///     assigning any tags or assign all tags.
  final List<Uri> _topLibraries;
  final PackageGraph _packageGraph;

  Tagger._(
    this.packageName,
    this._session,
    PubspecCache pubspecCache,
    this._isBinaryOnly,
    this._topLibraries,
    this._publicLibraries,
  )   : _pubspecCache = pubspecCache,
        _packageGraph = PackageGraph(pubspecCache);

  /// Assumes that `dart pub get` has been run.
  factory Tagger(String packageDir) {
    final session = ContextBuilder()
        .createContext(
          contextRoot: ContextLocator().locateRoots(
            includedPaths: [path.normalize(packageDir)],
          ).first,
        )
        .currentSession;
    final pubspecCache = PubspecCache(session);
    final pubspec = pubspecFromDir(packageDir);

    final libDartFiles = dartFilesFromLib(packageDir);
    final nonSrcDartFiles =
        libDartFiles.where((p) => !p.startsWith('src/')).toList();

    Uri? primaryLibrary;
    if (libDartFiles.contains('${pubspec.name}.dart')) {
      primaryLibrary =
          Uri.parse('package:${pubspec.name}/${pubspec.name}.dart');
    }

    // If there is a primary library, use it as a single source for top libraries,
    // otherwise take `lib/*.dart` or (if it was empty) `lib/**/*.dart`.
    List<Uri> topLibraries;
    if (primaryLibrary != null) {
      topLibraries = <Uri>[primaryLibrary];
    } else {
      topLibraries = (nonSrcDartFiles.isEmpty ? libDartFiles : nonSrcDartFiles)
          .map((name) => Uri.parse('package:${pubspec.name}/$name'))
          .toList();
    }

    final binDir = Directory(path.join(packageDir, 'bin'));
    final allBinFiles = binDir.existsSync()
        ? binDir
            .listSync(recursive: true)
            .where((e) => e is File && e.path.endsWith('.dart'))
            .map((f) => path.relative(f.path, from: binDir.path))
            .toList()
        : <String>[];
    final isBinaryOnly = nonSrcDartFiles.isEmpty && allBinFiles.isNotEmpty;

    final publicLibraries = nonSrcDartFiles
        .map((s) => Uri.parse('package:${pubspec.name}/$s'))
        .toList();
    return Tagger._(
      pubspec.name,
      session,
      pubspecCache,
      isBinaryOnly,
      topLibraries,
      publicLibraries,
    );
  }

  void sdkTags(List<String> tags, List<Explanation> explanations) {
    try {
      if (_isBinaryOnly) {
        tags.add(Sdk.dart.tag);
        explanations.add(Explanation('Binary only',
            'Cannot assign flutter SDK tag because it is binary only',
            tag: null));
      } else {
        for (final sdk in Sdk.knownSdks) {
          // Will find a path in the package graph where a package declares an sdk
          // not supported by [sdk].
          final violationResult =
              SdkViolationFinder(_packageGraph, sdk, _pubspecCache, _session)
                  .findSdkViolation(packageName, _topLibraries);
          if (violationResult != null) {
            explanations.add(violationResult);
          } else {
            tags.add(sdk.tag);
          }
        }
      }
    } on TagException catch (e) {
      explanations.add(Explanation(
        'Tag detection failed.',
        e.message,
        tag: null,
      ));
      return;
    }
  }

  /// Adds tags for the Flutter platforms that this package supports to [tags].
  ///
  /// Adds [Explanation]s to [explanations] for platforms not supported.
  void flutterPlatformTags(
    List<String> tags,
    List<Explanation> explanations, {
    bool trustDeclarations = true,
  }) {
    try {
      if (_isBinaryOnly) {
        explanations.add(Explanation('Binary only',
            'Cannot assign flutter platform tags, it is a binary only package',
            tag: null));
      } else {
        for (final flutterPlatform in FlutterPlatform.recognizedPlatforms) {
          final libraryGraph =
              LibraryGraph(_session, flutterPlatform.runtime.declaredVariables);
          final declaredPlatformDetector =
              DeclaredFlutterPlatformDetector(_pubspecCache);
          final violationFinder = PlatformViolationFinder(
            flutterPlatform,
            libraryGraph,
            declaredPlatformDetector,
            _pubspecCache,
            runtimeViolationFinder(
              libraryGraph,
              flutterPlatform.runtime,
              (List<Uri> path) => Explanation(
                'Package not compatible with runtime ${flutterPlatform.runtime.name} on ${flutterPlatform.name}',
                'Because:\n${LibraryGraph.formatPath(path)}',
                tag: flutterPlatform.tag,
              ),
            ),
          );

          // Wanting to trust the plugins annotations when assigning tags we make
          // a library graph that treats all libraries in plugins as leaf-nodes.
          //
          // In this way the plugin restrictions of its dependencies are not
          // restricting the result.
          //
          // We still keep the unpruned detection for providing Explanations.
          final prunedLibraryGraph = trustDeclarations
              ? LibraryGraph(
                  _session, flutterPlatform.runtime.declaredVariables,
                  isLeaf: declaredPlatformDetector.isFlutterPlugin)
              : libraryGraph;

          final prunedViolationFinder = PlatformViolationFinder(
              flutterPlatform,
              prunedLibraryGraph,
              declaredPlatformDetector,
              _pubspecCache,
              runtimeViolationFinder(
                  prunedLibraryGraph,
                  flutterPlatform.runtime,
                  (List<Uri> path) => Explanation(
                      'Package not compatible with runtime ${flutterPlatform.runtime.name} of ${flutterPlatform.name}',
                      'Because:\n${LibraryGraph.formatPath(path)}',
                      tag: flutterPlatform.tag)));
          // Report only the first non-pruned violation as Explanation
          final firstNonPrunedViolation = _topLibraries
              .map(violationFinder.findPlatformViolation)
              .firstWhere((e) => e != null, orElse: () => null);
          if (firstNonPrunedViolation != null) {
            explanations.add(firstNonPrunedViolation);
          }

          // Tag is supported, if there is no pruned violations
          final supports = _topLibraries
              .map(prunedViolationFinder.findPlatformViolation)
              .every((e) => e == null);

          if (supports) {
            tags.add(flutterPlatform.tag);
          }
        }
      }
    } on TagException catch (e) {
      explanations
          .add(Explanation('Tag detection failed.', e.message, tag: null));
      return;
    }
  }

  /// Adds tags for the Dart runtimes that this package supports to [tags].
  ///
  /// Adds [Explanation]s to [explanations] for runtimes not supported.
  void runtimeTags(List<String> tags, List<Explanation> explanations) {
    try {
      if (_isBinaryOnly) {
        tags.addAll(<String>[Runtime.nativeAot.tag, Runtime.nativeJit.tag]);
      } else {
        final dartSdkViolationFinder = SdkViolationFinder(
            _packageGraph, Sdk.dart, _pubspecCache, _session);
        if (dartSdkViolationFinder.findSdkViolation(
                packageName, _topLibraries) !=
            null) {
          // This is reported elsewhere
        } else {
          for (final runtime in Runtime.recognizedRuntimes) {
            final finder = runtimeViolationFinder(
                LibraryGraph(_session, runtime.declaredVariables),
                runtime,
                (List<Uri> path) => Explanation(
                    'Package not compatible with runtime ${runtime.name}',
                    'Because:\n${LibraryGraph.formatPath(path)}',
                    tag: runtime.tag));
            var supports = true;
            for (final lib in _topLibraries) {
              final violationResult = finder.findViolation(lib);
              if (violationResult != null) {
                explanations.add(violationResult);
                supports = false;
                break;
              }
            }
            if (supports) {
              tags.add(runtime.tag);
            }
          }
        }
      }
    } on TagException catch (e) {
      explanations
          .add(Explanation('Tag detection failed.', e.message, tag: null));
      return;
    }
  }

  /// Decides if a package is null-safe.
  ///
  /// A package is marked null safety compliant if:
  ///
  /// - The package and all its transitive dependencies have opted-in by
  ///   specifying a lower dart sdk bound >= 2.12.
  ///
  /// - No libraries in the import closure of [_publicLibraries] opt out of
  ///   null-safety. (For each runtime in [Runtime.recognizedRuntimes]).
  void nullSafetyTags(List<String> tags, List<Explanation> explanations) {
    const _nullSafeTag = 'is:null-safe';

    try {
      var foundIssues = false;

      final sdkConstraintFinder = PathFinder<String>(_packageGraph, (
        String packageDir,
      ) {
        final pubspec = _pubspecCache.pubspecOfPackage(packageDir);

        return pubspec.sdkConstraintStatus.hasOptedIntoNullSafety
            ? null
            : (path) => Explanation(
                  'Package is not null safe',
                  'Because:\n${PackageGraph.formatPath(path)} '
                      'that doesn\'t opt in to null safety',
                  tag: _nullSafeTag,
                );
      });

      final sdkConstraintResult =
          sdkConstraintFinder.findViolation(packageName);
      if (sdkConstraintResult != null) {
        explanations.add(sdkConstraintResult);
        foundIssues = true;
      } else {
        for (final runtime in Runtime.recognizedRuntimes) {
          final optOutViolationFinder = PathFinder<Uri>(
            LibraryGraph(_session, runtime.declaredVariables),
            (library) {
              if (library.scheme == 'dart-ext') return null;
              final resolvedPath = _session.uriConverter.uriToPath(library);
              if (resolvedPath == null) {
                return (path) => Explanation(
                      'Unable to access import.',
                      'Because:\n${LibraryGraph.formatPath(path)} where $library is inaccessible.',
                      tag: _nullSafeTag,
                    );
              }
              final unit = parsedUnitFromUri(_session, library);
              if (unit == null) return null;
              final languageVersionToken = unit.languageVersionToken;
              if (languageVersionToken == null) return null;
              // dart:ui has no package name. So we cannot trivially look it up in
              // the allowed experiments. We just assume it is opted in.
              if (!library.isScheme('package')) return null;
              if (!isNullSafety(Version(
                  languageVersionToken.major, languageVersionToken.minor, 0))) {
                return (path) => Explanation(
                      'Package is not null safe',
                      'Because:\n${LibraryGraph.formatPath(path)} where $library '
                          'is opting out from null safety.',
                      tag: _nullSafeTag,
                    );
              }
              return null;
            },
          );

          for (final library in _publicLibraries) {
            final nullSafetyResult =
                optOutViolationFinder.findViolation(library);
            if (nullSafetyResult != null) {
              explanations.add(nullSafetyResult);
              foundIssues = true;
            }
          }
          // If we have a problem one runtime, there is no need to explore the
          // other runtimes... Also if we do, we are likely to just duplicate
          // explanations.
          if (foundIssues) {
            break;
          }
        }
      }

      if (!foundIssues) {
        tags.add(_nullSafeTag);
      }
    } on TagException catch (e) {
      explanations.add(Explanation(
        'Tag detection failed.',
        e.message,
        tag: _nullSafeTag,
      ));
    }
  }
}
