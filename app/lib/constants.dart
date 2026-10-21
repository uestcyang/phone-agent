/// Build-time defaults contain no deployed endpoint or credential.
const String kDefaultHost = String.fromEnvironment(
  'PA_HOST',
  defaultValue: 'localhost',
);
const int kDefaultPort = int.fromEnvironment('PA_PORT', defaultValue: 8080);

const bool kCoreEdition = bool.fromEnvironment(
  'PA_CORE_EDITION',
  defaultValue: true,
);
