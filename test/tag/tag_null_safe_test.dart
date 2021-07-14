// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'package:pana/src/tag/tagger.dart';

import '../package_descriptor.dart';

void expectTagging(void Function(List<String>, List<Explanation>) f,
    {dynamic tags = anything, dynamic explanations = anything}) {
  final actualTags = <String>[];
  final actualExplanations = <Explanation>[];
  f(actualTags, actualExplanations);
  expect(actualTags, tags);
  if (explanations != null) {
    expect(actualExplanations, explanations);
  }
}

void main() {
  group('null-safe', () {
    test('compliant package depending on compliant package gets the tag',
        () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps('my_package',
            dependencies: ['my_dependency'],
            sdkConstraint: '>=2.12.0 <3.0.0',
            lib: [
              d.file('my_package.dart', 'int fourtyTwo() => 42;'),
            ]),
        packageWithPathDeps('my_dependency',
            sdkConstraint: '>=2.13.0 <3.0.0',
            lib: [
              d.file(
                'my_dependency.dart',
                "import 'dart:io'; int fourtyThree() => 43;",
              ),
            ]),
      ]);
      await descriptor.create();
      final tagger = Tagger(p.join(descriptor.io.path, 'my_package'));
      expectTagging(tagger.nullSafetyTags,
          tags: ['is:null-safe'], explanations: isEmpty);
    });

    test('Depending on the 2.12 beta sdk gets the tag', () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps('my_package',
            sdkConstraint: '>=2.12.0-beta1 <3.0.0',
            lib: [
              d.file('my_package.dart', 'int fourtyTwo() => 42;'),
            ]),
      ]);
      await descriptor.create();
      final tagger = Tagger(p.join(descriptor.io.path, 'my_package'));
      expectTagging(tagger.nullSafetyTags,
          tags: ['is:null-safe'], explanations: isEmpty);
    });
    test('opting a library not reachable from public out still gets tag',
        () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps('my_package',
            sdkConstraint: '>=2.13.0 <3.0.0',
            lib: [
              d.file('my_package.dart', 'int fourtyTwo() => 42;'),
              d.dir('src', [
                d.file(
                  'stray_file.dart',
                  '''
// @dart = 2.3''',
                ),
              ]),
            ]),
      ]);

      await descriptor.create();
      final tagger = Tagger('${descriptor.io.path}/my_package');
      expectTagging(tagger.nullSafetyTags,
          tags: ['is:null-safe'], explanations: isEmpty);
    });

    test('opting a library to older version still allowing null safety is ok',
        () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps('my_package',
            sdkConstraint: '>=2.13.0 <3.0.0',
            lib: [
              d.file('my_package.dart', 'int fourtyTwo() => 42;'),
              d.dir('src', [
                d.file('stray_file.dart', '// @dart = 2.12\n'),
              ]),
            ])
      ]);
      await descriptor.create();
      final tagger = Tagger(p.join(descriptor.io.path, 'my_package'));
      expectTagging(tagger.nullSafetyTags,
          tags: ['is:null-safe'], explanations: isEmpty);
    });

    test('depending on a not-null-safe package gets fails', () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps('my_package',
            dependencies: ['my_dependency'],
            sdkConstraint: '>=2.12.0 <3.0.0',
            lib: [
              d.file('my_package.dart', 'int fourtyTwo() => 42;'),
            ]),
        packageWithPathDeps('my_dependency',
            sdkConstraint: '>=2.9.0 <3.0.0',
            lib: [
              d.file(
                'my_dependency.dart',
                "import 'dart:io'; int fourtyThree() => 43;",
              ),
            ]),
      ]);
      await descriptor.create();
      final tagger = Tagger('${descriptor.io.path}/my_package');
      expectTagging(tagger.nullSafetyTags, tags: isEmpty, explanations: [
        explanation(finding: 'Package is not null safe', explanation: '''
Because:
* `my_package` that depends on:
* `my_dependency` that doesn't opt in to null safety''')
      ]);
    });

    test('allow non-imported opt-outed library in dependency', () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps('my_package',
            dependencies: ['my_dependency'],
            sdkConstraint: '>=2.12.0 <3.0.0',
            lib: [
              d.file('my_package.dart', 'int fourtyTwo() => 42;'),
            ]),
        packageWithPathDeps('my_dependency',
            sdkConstraint: '>=2.12.0 <3.0.0',
            lib: [
              d.file(
                'my_dependency.dart',
                '// @dart = 2.9',
              ),
            ]),
      ]);
      await descriptor.create();
      final tagger = Tagger('${descriptor.io.path}/my_package');
      expectTagging(tagger.nullSafetyTags,
          tags: ['is:null-safe'], explanations: isEmpty);
    });

    test('disallow imported opt-outed library in dependency', () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps('my_package',
            dependencies: ['my_dependency'],
            sdkConstraint: '>=2.12.0 <3.0.0',
            lib: [
              d.file('my_package.dart', '''
                import 'package:my_dependency/my_dependency.dart';

                int fourtyTwo() => 42;
              '''),
            ]),
        packageWithPathDeps('my_dependency',
            sdkConstraint: '>=2.12.0 <3.0.0',
            lib: [
              d.file(
                'my_dependency.dart',
                '// @dart = 2.9',
              ),
            ]),
      ]);
      await descriptor.create();
      final tagger = Tagger('${descriptor.io.path}/my_package');
      expectTagging(tagger.nullSafetyTags, tags: isEmpty, explanations: [
        explanation(finding: 'Package is not null safe', explanation: '''
Because:
* `package:my_package/my_package.dart` that imports:
* `package:my_dependency/my_dependency.dart` where package:my_dependency/my_dependency.dart is opting out from null safety.''')
      ]);
    });

    test('An opt-out test still gets tag', () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps('my_package',
            sdkConstraint: '>=2.12.0 <3.0.0',
            lib: [
              d.file('my_package.dart', 'int fourtyTwo() => 42;'),
            ],
            extraFiles: [
              d.dir('test', [
                d.file('main_test.dart', '''
// @dart = 2.9
import 'package:my_package/my_package.dart';

void main() {
  if (!fourtyTwo() == 42) throw 'failed';
}
''')
              ])
            ]),
      ]);
      await descriptor.create();
      final tagger = Tagger(p.join(descriptor.io.path, 'my_package'));
      expectTagging(tagger.nullSafetyTags,
          tags: ['is:null-safe'], explanations: isEmpty);
    });

    test('Broken imports gets reported', () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps('my_package',
            sdkConstraint: '>=2.12.0 <3.0.0',
            lib: [
              d.file(
                  'my_package.dart', 'import "package:missing/missing.dart";'),
            ],
            dependencies: [
              'missing'
            ]),
      ]);
      await descriptor.create();
      final tagger = Tagger(p.join(descriptor.io.path, 'my_package'));
      final tagDetectionFailed = contains(
        explanation(
          finding: 'Tag detection failed.',
        ),
      );

      expectTagging(
        tagger.nullSafetyTags,
        explanations: tagDetectionFailed,
      );
      expectTagging(
        tagger.flutterPlatformTags,
        explanations: tagDetectionFailed,
      );
      expectTagging(
        tagger.sdkTags,
        explanations: tagDetectionFailed,
      );
      expectTagging(
        tagger.runtimeTags,
        explanations: tagDetectionFailed,
      );
    });

    test('dart-ext: import gets ignored', () async {
      final descriptor = d.dir('cache', [
        packageWithPathDeps(
          'my_package',
          sdkConstraint: '>=2.12.0 <3.0.0',
          lib: [
            d.file('my_package.dart', 'import "dart-ext:rpi_gpio_ext";'),
          ],
        ),
      ]);
      await descriptor.create();
      final tagger = Tagger(p.join(descriptor.io.path, 'my_package'));
      expectTagging(
        tagger.nullSafetyTags,
        tags: ['is:null-safe'],
        explanations: isEmpty,
      );
    });
  });
}

Matcher explanation({finding = anything, explanation = anything}) {
  return allOf(
    HasFinding(finding),
    HasDescription(explanation),
  );
}

class HasDescription extends CustomMatcher {
  HasDescription(matcher) : super('Explanation with a', 'explanation', matcher);

  @override
  String? featureValueOf(actual) => (actual as Explanation).explanation;
}

class HasFinding extends CustomMatcher {
  HasFinding(matcher) : super('Explanation with a', 'finding', matcher);

  @override
  String featureValueOf(actual) => (actual as Explanation).finding;
}
