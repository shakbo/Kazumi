// DanDanPlay API credentials for the client signature flow.
// Release/PR CI injects them via --dart-define=DANDANAPI_APPID / DANDANAPI_KEY.
const _envId = String.fromEnvironment('DANDANAPI_APPID');
const _envValue = String.fromEnvironment('DANDANAPI_KEY');

const Map<String, String> dandanCredentials = {
  'id': (_envId == '') ? 'qb998n8g3u' : _envId,
  'value': (_envValue == '') ? '4y2waS6A6yb4uw7Dhd9pmdTzvrF7YUsg' : _envValue,
};
