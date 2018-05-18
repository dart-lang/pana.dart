// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'package:json_serializable/json_serializable.dart';

import 'src/version_builder.dart';
import 'src/version_helper.dart';

Builder buildPana([_]) {
  return new PartBuilder([
    new JsonSerializableGenerator.withDefaultHelpers([
      new VersionHelper(),
      new VersionConstraintHelper(),
    ])
  ], header: copyrightHeader);
}

Builder versionBuilder([_]) => new PackageVersionBulder();