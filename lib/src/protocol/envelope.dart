class JsonBody {
  JsonBody({
    required this.d,
    required this.n,
    required this.s,
    required this.r,
    required this.t,
    required this.p,
    required this.u,
    this.e,
  });

  String d;
  String n;
  String s;
  String r;
  int t;
  int p;
  int u;
  String? e;

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'd': d,
      'n': n,
      's': s,
      'r': r,
      't': t,
      'p': p,
      'u': u,
    };
    if (e != null) {
      out['e'] = e;
    }
    return out;
  }
}

class JsonResp {
  JsonResp({
    required this.d,
    required this.n,
    required this.s,
    required this.c,
    required this.t,
    required this.p,
    this.m,
    this.e,
    this.r,
  });

  final String d;
  final String n;
  final String s;
  final int c;
  final int t;
  final int p;
  final String? m;
  final String? e;
  final String? r;

  factory JsonResp.fromJson(Map<String, dynamic> data) {
    return JsonResp(
      d: data['d']?.toString() ?? '',
      n: data['n']?.toString() ?? '',
      s: data['s']?.toString() ?? '',
      c: (data['c'] as num?)?.toInt() ?? 0,
      t: (data['t'] as num?)?.toInt() ?? 0,
      p: (data['p'] as num?)?.toInt() ?? 0,
      m: data['m']?.toString(),
      e: data['e']?.toString(),
      r: data['r']?.toString(),
    );
  }
}

class AuthToken {
  AuthToken({
    required this.token,
    required this.secret,
    required this.expired,
  });

  final String token;
  final String secret;
  final int expired;

  factory AuthToken.fromJson(Map<String, dynamic> data) {
    return AuthToken(
      token: data['token']?.toString() ?? '',
      secret: data['secret']?.toString() ?? '',
      expired: (data['expired'] as num?)?.toInt() ?? 0,
    );
  }
}

bool planRequiresOuterSignature(int plan) => plan == 2;

bool jsonBodyRequiresOuterSignature(int plan, {bool plan2KeyBootstrap = false}) {
  if (plan == 2) return true;
  return plan2KeyBootstrap && plan == 0;
}
