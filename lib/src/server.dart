import 'dart:async';
import 'dart:convert';
import 'package:angel_framework/angel_framework.dart';
import 'exception.dart';
import 'response.dart';
import 'token_type.dart';

/// A request handler that performs an arbitrary authorization token grant.
typedef Future<AuthorizationTokenResponse> ExtensionGrant(
    RequestContext req, ResponseContext res);

Future<String> _getParam(RequestContext req, String name, String state,
    {bool body: false}) async {
  Map<String, dynamic> data;

  if (body == true) {
    data = await req.parseBody().then((_) => req.bodyAsMap);
  } else {
    data = req.queryParameters;
  }

  var value = data.containsKey(name) ? data[name]?.toString() : null;

  if (value?.isNotEmpty != true) {
    throw new AuthorizationException(
      new ErrorResponse(
        ErrorResponse.invalidRequest,
        'Missing required parameter "$name".',
        state,
      ),
      statusCode: 400,
    );
  }

  return value;
}

Future<Iterable<String>> _getScopes(RequestContext req,
    {bool body: false}) async {
  Map<String, dynamic> data;

  if (body == true) {
    data = await req.parseBody().then((_) => req.bodyAsMap);
  } else {
    data = req.queryParameters;
  }

  return data['scope']?.toString()?.split(' ') ?? [];
}

/// An OAuth2 authorization server, which issues access tokens to third parties.
abstract class AuthorizationServer<Client, User> {
  const AuthorizationServer();

  static const String _internalServerError =
      'An internal server error occurred.';

  /// A [Map] of custom authorization token grants. Use this to handle custom grant types, perhaps even your own.
  Map<String, ExtensionGrant> get extensionGrants => {};

  /// Finds the [Client] application associated with the given [clientId].
  FutureOr<Client> findClient(String clientId);

  /// Verify that a [client] is the one identified by the [clientSecret].
  Future<bool> verifyClient(Client client, String clientSecret);

  /// Prompt the currently logged-in user to grant or deny access to the [client].
  ///
  /// In many applications, this will entail showing a dialog to the user in question.
  requestAuthorizationCode(
      Client client,
      String redirectUri,
      Iterable<String> scopes,
      String state,
      RequestContext req,
      ResponseContext res) {
    throw new AuthorizationException(
      new ErrorResponse(
        ErrorResponse.unsupportedResponseType,
        'Authorization code grants are not supported.',
        state,
      ),
      statusCode: 400,
    );
  }

  /// Create an implicit authorization token.
  ///
  /// Note that in cases where this is called, there is no guarantee
  /// that the user agent has not been compromised.
  Future<AuthorizationTokenResponse> implicitGrant(
      Client client,
      String redirectUri,
      Iterable<String> scopes,
      String state,
      RequestContext req,
      ResponseContext res) {
    throw new AuthorizationException(
      new ErrorResponse(
        ErrorResponse.unsupportedResponseType,
        'Authorization code grants are not supported.',
        state,
      ),
      statusCode: 400,
    );
  }

  /// Exchanges an authorization code for an authorization token.
  Future<AuthorizationTokenResponse> exchangeAuthorizationCodeForToken(
      String authCode,
      String redirectUri,
      RequestContext req,
      ResponseContext res) {
    throw new AuthorizationException(
      new ErrorResponse(
        ErrorResponse.unsupportedResponseType,
        'Authorization code grants are not supported.',
        req.uri.queryParameters['state'] ?? '',
      ),
      statusCode: 400,
    );
  }

  /// Refresh an authorization token.
  Future<AuthorizationTokenResponse> refreshAuthorizationToken(
      Client client,
      String refreshToken,
      Iterable<String> scopes,
      RequestContext req,
      ResponseContext res) async {
    var body = await req.parseBody().then((_) => req.bodyAsMap);
    throw new AuthorizationException(
      new ErrorResponse(
        ErrorResponse.unsupportedResponseType,
        'Refreshing authorization tokens is not supported.',
        body['state']?.toString() ?? '',
      ),
      statusCode: 400,
    );
  }

  /// Issue an authorization token to a user after authenticating them via [username] and [password].
  Future<AuthorizationTokenResponse> resourceOwnerPasswordCredentialsGrant(
      Client client,
      String username,
      String password,
      Iterable<String> scopes,
      RequestContext req,
      ResponseContext res) async {
    var body = await req.parseBody().then((_) => req.bodyAsMap);
    throw new AuthorizationException(
      new ErrorResponse(
        ErrorResponse.unsupportedResponseType,
        'Resource owner password credentials grants are not supported.',
        body['state']?.toString() ?? '',
      ),
      statusCode: 400,
    );
  }

  /// Performs a client credentials grant. Only use this in situations where the client is 100% trusted.
  Future<AuthorizationTokenResponse> clientCredentialsGrant(
      Client client, RequestContext req, ResponseContext res) async {
    var body = await req.parseBody().then((_) => req.bodyAsMap);
    throw new AuthorizationException(
      new ErrorResponse(
        ErrorResponse.unsupportedResponseType,
        'Client credentials grants are not supported.',
        body['state']?.toString() ?? '',
      ),
      statusCode: 400,
    );
  }

  /// A request handler that invokes the correct logic, depending on which type
  /// of grant the client is requesting.
  Future authorizationEndpoint(RequestContext req, ResponseContext res) async {
    String state = '';

    try {
      var query = req.queryParameters;
      state = query['state']?.toString() ?? '';
      var responseType = await _getParam(req, 'response_type', state);

      if (responseType == 'code') {
        // Ensure client ID
        // TODO: Handle confidential clients
        var clientId = await _getParam(req, 'client_id', state);

        // Find client
        var client = await findClient(clientId);

        if (client == null) {
          throw new AuthorizationException(new ErrorResponse(
            ErrorResponse.unauthorizedClient,
            'Unknown client "$clientId".',
            state,
          ));
        }

        // Grab redirect URI
        var redirectUri = await _getParam(req, 'redirect_uri', state);

        // Grab scopes
        var scopes = await _getScopes(req);

        return await requestAuthorizationCode(
            client, redirectUri, scopes, state, req, res);
      }

      if (responseType == 'token') {
        var clientId = await _getParam(req, 'client_id', state);
        var client = await findClient(clientId);

        if (client == null) {
          throw new AuthorizationException(new ErrorResponse(
            ErrorResponse.unauthorizedClient,
            'Unknown client "$clientId".',
            state,
          ));
        }

        var redirectUri = await _getParam(req, 'redirect_uri', state);

        // Grab scopes
        var scopes = await _getScopes(req);
        var token =
            await implicitGrant(client, redirectUri, scopes, state, req, res);

        Uri target;

        try {
          target = Uri.parse(redirectUri);
          var queryParameters = <String, String>{};

          queryParameters.addAll({
            'access_token': token.accessToken,
            'token_type': 'bearer',
            'state': state,
          });

          if (token.expiresIn != null)
            queryParameters['expires_in'] = token.expiresIn.toString();

          if (token.scope != null)
            queryParameters['scope'] = token.scope.join(' ');

          var fragment = queryParameters.keys
              .fold<StringBuffer>(new StringBuffer(), (buf, k) {
            if (buf.isNotEmpty) buf.write('&');
            return buf
              ..write(
                '$k=' + Uri.encodeComponent(queryParameters[k]),
              );
          }).toString();

          target = target.replace(fragment: fragment);
          res.redirect(target.toString());
          return false;
        } on FormatException {
          throw new AuthorizationException(
              new ErrorResponse(
                ErrorResponse.invalidRequest,
                'Invalid URI provided as "redirect_uri" parameter',
                state,
              ),
              statusCode: 400);
        }
      }

      throw new AuthorizationException(
          new ErrorResponse(
            ErrorResponse.invalidRequest,
            'Invalid or no "response_type" parameter provided',
            state,
          ),
          statusCode: 400);
    } on AngelHttpException {
      rethrow;
    } catch (e, st) {
      throw new AuthorizationException(
        new ErrorResponse(
          ErrorResponse.serverError,
          _internalServerError,
          state,
        ),
        error: e,
        statusCode: 500,
        stackTrace: st,
      );
    }
  }

  static final RegExp _rgxBasic = new RegExp(r'Basic ([^$]+)');
  static final RegExp _rgxBasicAuth = new RegExp(r'([^:]*):([^$]*)');

  /// A request handler that either exchanges authorization codes for authorization tokens,
  /// or refreshes authorization tokens.
  Future tokenEndpoint(RequestContext req, ResponseContext res) async {
    String state = '';
    Client client;

    try {
      AuthorizationTokenResponse response;
      var body = await req.parseBody().then((_) => req.bodyAsMap);

      state = body['state']?.toString() ?? '';

      var grantType = await _getParam(req, 'grant_type', state, body: true);

      if (grantType != 'authorization_code') {
        var match =
            _rgxBasic.firstMatch(req.headers.value('authorization') ?? '');

        if (match != null) {
          match = _rgxBasicAuth
              .firstMatch(new String.fromCharCodes(base64Url.decode(match[1])));
        }

        if (match == null) {
          throw new AuthorizationException(
            new ErrorResponse(
              ErrorResponse.unauthorizedClient,
              'Invalid or no "Authorization" header.',
              state,
            ),
            statusCode: 400,
          );
        } else {
          var clientId = match[1], clientSecret = match[2];
          client = await findClient(clientId);

          if (client == null) {
            throw new AuthorizationException(
              new ErrorResponse(
                ErrorResponse.unauthorizedClient,
                'Invalid "client_id" parameter.',
                state,
              ),
              statusCode: 400,
            );
          }

          if (!await verifyClient(client, clientSecret)) {
            throw new AuthorizationException(
              new ErrorResponse(
                ErrorResponse.unauthorizedClient,
                'Invalid "client_secret" parameter.',
                state,
              ),
              statusCode: 400,
            );
          }
        }
      }

      if (grantType == 'authorization_code') {
        var code = await _getParam(req, 'code', state, body: true);
        var redirectUri =
            await _getParam(req, 'redirect_uri', state, body: true);
        response = await exchangeAuthorizationCodeForToken(
            code, redirectUri, req, res);
      } else if (grantType == 'refresh_token') {
        var refreshToken =
            await _getParam(req, 'refresh_token', state, body: true);
        var scopes = await _getScopes(req);
        response = await refreshAuthorizationToken(
            client, refreshToken, scopes, req, res);
      } else if (grantType == 'password') {
        var username = await _getParam(req, 'username', state, body: true);
        var password = await _getParam(req, 'password', state, body: true);
        var scopes = await _getScopes(req);
        response = await resourceOwnerPasswordCredentialsGrant(
            client, username, password, scopes, req, res);
      } else if (grantType == 'client_credentials') {
        response = await clientCredentialsGrant(client, req, res);

        if (response.refreshToken != null) {
          // Remove refresh token
          response = new AuthorizationTokenResponse(
            response.accessToken,
            expiresIn: response.expiresIn,
            scope: response.scope,
          );
        }
      } else if (extensionGrants.containsKey(grantType)) {
        response = await extensionGrants[grantType](req, res);
      }

      if (response != null) {
        return <String, dynamic>{'token_type': AuthorizationTokenType.bearer}
          ..addAll(response.toJson());
      }

      throw new AuthorizationException(
        new ErrorResponse(
          ErrorResponse.invalidRequest,
          'Invalid or no "grant_type" parameter provided',
          state,
        ),
        statusCode: 400,
      );
    } on AngelHttpException {
      rethrow;
    } catch (e, st) {
      throw new AuthorizationException(
        new ErrorResponse(
          ErrorResponse.serverError,
          _internalServerError,
          state,
        ),
        error: e,
        statusCode: 500,
        stackTrace: st,
      );
    }
  }
}
