# Appcircle Android Version Code and Version Name Increment

This component bumps the version `versionCode` and `versionName` according to the given strategies.

## Required Input Variables

- `$AC_REPOSITORY_DIR`: Specifies the cloned repository directory.
- `$AC_BUILD_NUMBER_SOURCE`: Version code source type(env,gradle)
- `$AC_ANDROID_BUILD_NUMBER`: Version code to set. If `$AC_BUILD_NUMBER_SOURCE` is set to `gradle`, this variable will be read from the project
- `$AC_BUILD_OFFSET`: The number to be added or subtracted from the `$AC_ANDROID_BUILD_NUMBER` Negative values can be written such as `-10`. Default is `1`
- `$AC_VERSION_NUMBER_SOURCE`: Version name source type(env,gradle)
- `$AC_ANDROID_VERSION_NUMBER`: Version name to set. If `$AC_VERSION_NUMBER_SOURCE` is set to `gradle`, this variable will be read from the project
- `$AC_VERSION_STRATEGY`: Version Increment Strategy major, minor, patch or keep. Default is `keep`
- `$AC_VERSION_OFFSET`: The number to be added or subtracted from the  `$AC_IOS_VERSION_NUMBER` Negative values can be written such as `-10`. Default is `0`

## Optional Input Variables

- `$AC_PROJECT_PATH`: Specifies Android project path. Default is repository folder.
- `$AC_VERSION_FLAVOR`: Name of the flavor to update. Default is none.
- `$AC_OMIT_ZERO_PATCH_VERSION`: If true omits zero in patch version(so 42.10.0 will become 42.10 and 42.10.1 will remain 42.10.1), default is `false`

## Output Variables

- `$AC_ANDROID_NEW_BUILD_NUMBER`: Changed build number
- `$AC_ANDROID_NEW_VERSION_NUMBER`: Changed version number

## Running tests

Requires [RSpec](https://rspec.info) gem and Ruby standard library. No Gemfile or Bundler needed.

```bash
ruby test/test_main.rb
```

A pass/fail summary and a coverage report are printed at the end of each run.

## Credits

[Fastlane Android Versioning Plugin](https://github.com/otkmnb2783/fastlane-plugin-android_versioning)
