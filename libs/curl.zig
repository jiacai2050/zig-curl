const std = @import("std");

pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "curl",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const curl_dep = b.lazyDependency("curl", .{
        .target = target,
        .optimize = optimize,
    }) orelse return null;

    inline for (srcs) |s| {
        lib.addCSourceFile(.{
            .file = curl_dep.path(s),
            .flags = &.{"-std=gnu89"},
        });
    }
    lib.addIncludePath(curl_dep.path("lib"));
    lib.addIncludePath(curl_dep.path("include"));
    lib.installHeadersDirectory(curl_dep.path("include/curl"), "curl", .{});
    lib.defineCMacro("BUILDING_LIBCURL", null);
    lib.defineCMacro("CURL_STATICLIB", "1");
    lib.defineCMacro("CURL_DISABLE_LDAP", "1");
    lib.defineCMacro("CURL_DISABLE_LDAPS", "1");
    lib.defineCMacro("USE_MBEDTLS", "1");
    lib.defineCMacro("CURL_DISABLE_DICT", "1");
    lib.defineCMacro("CURL_DISABLE_FILE", "1");
    lib.defineCMacro("CURL_DISABLE_FTP", "1");
    lib.defineCMacro("CURL_DISABLE_GOPHER", "1");
    lib.defineCMacro("CURL_DISABLE_IMAP", "1");
    lib.defineCMacro("CURL_DISABLE_MQTT", "1");
    lib.defineCMacro("CURL_DISABLE_POP3", "1");
    lib.defineCMacro("CURL_DISABLE_RTSP", "1");
    lib.defineCMacro("CURL_DISABLE_SMB", "1");
    lib.defineCMacro("CURL_DISABLE_SMTP", "1");
    lib.defineCMacro("CURL_DISABLE_TELNET", "1");
    lib.defineCMacro("CURL_DISABLE_TFTP", "1");
    lib.defineCMacro("HAVE_LIBZ", "1");
    lib.defineCMacro("HAVE_ZLIB_H", "1");
    if (target.result.os.tag == .windows) {
        lib.linkSystemLibrary("bcrypt");
        return lib;
    }
    lib.defineCMacro("CURL_EXTERN_SYMBOL", "__attribute__ ((__visibility__ (\"default\"))");

    const isDarwin = target.result.isDarwin();
    if (!isDarwin)
        lib.defineCMacro("ENABLE_IPV6", "1");
    lib.defineCMacro("HAVE_ALARM", "1");
    lib.defineCMacro("HAVE_ALLOCA_H", "1");
    lib.defineCMacro("HAVE_ARPA_INET_H", "1");
    lib.defineCMacro("HAVE_ARPA_TFTP_H", "1");
    lib.defineCMacro("HAVE_ASSERT_H", "1");
    lib.defineCMacro("HAVE_BASENAME", "1");
    lib.defineCMacro("HAVE_BOOL_T", "1");
    lib.defineCMacro("HAVE_BUILTIN_AVAILABLE", "1");
    lib.defineCMacro("HAVE_CLOCK_GETTIME_MONOTONIC", "1");
    lib.defineCMacro("HAVE_DLFCN_H", "1");
    lib.defineCMacro("HAVE_ERRNO_H", "1");
    lib.defineCMacro("HAVE_FCNTL", "1");
    lib.defineCMacro("HAVE_FCNTL_H", "1");
    lib.defineCMacro("HAVE_FCNTL_O_NONBLOCK", "1");
    lib.defineCMacro("HAVE_FREEADDRINFO", "1");
    lib.defineCMacro("HAVE_FTRUNCATE", "1");
    lib.defineCMacro("HAVE_GETADDRINFO", "1");
    lib.defineCMacro("HAVE_GETEUID", "1");
    lib.defineCMacro("HAVE_GETPPID", "1");
    lib.defineCMacro("HAVE_GETHOSTBYNAME", "1");
    if (!isDarwin)
        lib.defineCMacro("HAVE_GETHOSTBYNAME_R", "1");
    lib.defineCMacro("HAVE_GETHOSTBYNAME_R_6", "1");
    lib.defineCMacro("HAVE_GETHOSTNAME", "1");
    lib.defineCMacro("HAVE_GETPPID", "1");
    lib.defineCMacro("HAVE_GETPROTOBYNAME", "1");
    lib.defineCMacro("HAVE_GETPEERNAME", "1");
    lib.defineCMacro("HAVE_GETSOCKNAME", "1");
    lib.defineCMacro("HAVE_IF_NAMETOINDEX", "1");
    lib.defineCMacro("HAVE_GETPWUID", "1");
    lib.defineCMacro("HAVE_GETPWUID_R", "1");
    lib.defineCMacro("HAVE_GETRLIMIT", "1");
    lib.defineCMacro("HAVE_GETTIMEOFDAY", "1");
    lib.defineCMacro("HAVE_GMTIME_R", "1");
    lib.defineCMacro("HAVE_IFADDRS_H", "1");
    lib.defineCMacro("HAVE_INET_ADDR", "1");
    lib.defineCMacro("HAVE_INET_PTON", "1");
    lib.defineCMacro("HAVE_SA_FAMILY_T", "1");
    lib.defineCMacro("HAVE_INTTYPES_H", "1");
    lib.defineCMacro("HAVE_IOCTL", "1");
    lib.defineCMacro("HAVE_IOCTL_FIONBIO", "1");
    lib.defineCMacro("HAVE_IOCTL_SIOCGIFADDR", "1");
    lib.defineCMacro("HAVE_LDAP_URL_PARSE", "1");
    lib.defineCMacro("HAVE_LIBGEN_H", "1");
    lib.defineCMacro("HAVE_IDN2_H", "1");
    lib.defineCMacro("HAVE_LL", "1");
    lib.defineCMacro("HAVE_LOCALE_H", "1");
    lib.defineCMacro("HAVE_LOCALTIME_R", "1");
    lib.defineCMacro("HAVE_LONGLONG", "1");
    lib.defineCMacro("HAVE_MALLOC_H", "1");
    lib.defineCMacro("HAVE_MEMORY_H", "1");
    if (!isDarwin)
        lib.defineCMacro("HAVE_MSG_NOSIGNAL", "1");
    lib.defineCMacro("HAVE_NETDB_H", "1");
    lib.defineCMacro("HAVE_NETINET_IN_H", "1");
    lib.defineCMacro("HAVE_NETINET_TCP_H", "1");

    if (target.result.os.tag == .linux)
        lib.defineCMacro("HAVE_LINUX_TCP_H", "1");
    lib.defineCMacro("HAVE_NET_IF_H", "1");
    lib.defineCMacro("HAVE_PIPE", "1");
    lib.defineCMacro("HAVE_POLL", "1");
    lib.defineCMacro("HAVE_POLL_FINE", "1");
    lib.defineCMacro("HAVE_POLL_H", "1");
    lib.defineCMacro("HAVE_POSIX_STRERROR_R", "1");
    lib.defineCMacro("HAVE_PTHREAD_H", "1");
    lib.defineCMacro("HAVE_PWD_H", "1");
    lib.defineCMacro("HAVE_RECV", "1");
    lib.defineCMacro("HAVE_SELECT", "1");
    lib.defineCMacro("HAVE_SEND", "1");
    lib.defineCMacro("HAVE_FSETXATTR", "1");
    lib.defineCMacro("HAVE_FSETXATTR_5", "1");
    lib.defineCMacro("HAVE_SETJMP_H", "1");
    lib.defineCMacro("HAVE_SETLOCALE", "1");
    lib.defineCMacro("HAVE_SETRLIMIT", "1");
    lib.defineCMacro("HAVE_SETSOCKOPT", "1");
    lib.defineCMacro("HAVE_SIGACTION", "1");
    lib.defineCMacro("HAVE_SIGINTERRUPT", "1");
    lib.defineCMacro("HAVE_SIGNAL", "1");
    lib.defineCMacro("HAVE_SIGNAL_H", "1");
    lib.defineCMacro("HAVE_SIGSETJMP", "1");
    lib.defineCMacro("HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID", "1");
    lib.defineCMacro("HAVE_SOCKET", "1");
    lib.defineCMacro("HAVE_STDBOOL_H", "1");
    lib.defineCMacro("HAVE_STDINT_H", "1");
    lib.defineCMacro("HAVE_STDIO_H", "1");
    lib.defineCMacro("HAVE_STDLIB_H", "1");
    lib.defineCMacro("HAVE_STRCASECMP", "1");
    lib.defineCMacro("HAVE_STRDUP", "1");
    lib.defineCMacro("HAVE_STRERROR_R", "1");
    lib.defineCMacro("HAVE_STRINGS_H", "1");
    lib.defineCMacro("HAVE_STRING_H", "1");
    lib.defineCMacro("HAVE_STRSTR", "1");
    lib.defineCMacro("HAVE_STRTOK_R", "1");
    lib.defineCMacro("HAVE_STRTOLL", "1");
    lib.defineCMacro("HAVE_STRUCT_SOCKADDR_STORAGE", "1");
    lib.defineCMacro("HAVE_STRUCT_TIMEVAL", "1");
    lib.defineCMacro("HAVE_SYS_IOCTL_H", "1");
    lib.defineCMacro("HAVE_SYS_PARAM_H", "1");
    lib.defineCMacro("HAVE_SYS_POLL_H", "1");
    lib.defineCMacro("HAVE_SYS_RESOURCE_H", "1");
    lib.defineCMacro("HAVE_SYS_SELECT_H", "1");
    lib.defineCMacro("HAVE_SYS_SOCKET_H", "1");
    lib.defineCMacro("HAVE_SYS_STAT_H", "1");
    lib.defineCMacro("HAVE_SYS_TIME_H", "1");
    lib.defineCMacro("HAVE_SYS_TYPES_H", "1");
    lib.defineCMacro("HAVE_SYS_UIO_H", "1");
    lib.defineCMacro("HAVE_SYS_UN_H", "1");
    lib.defineCMacro("HAVE_TERMIOS_H", "1");
    lib.defineCMacro("HAVE_TERMIO_H", "1");
    lib.defineCMacro("HAVE_TIME_H", "1");
    lib.defineCMacro("HAVE_UNAME", "1");
    lib.defineCMacro("HAVE_UNISTD_H", "1");
    lib.defineCMacro("HAVE_UTIME", "1");
    lib.defineCMacro("HAVE_UTIMES", "1");
    lib.defineCMacro("HAVE_UTIME_H", "1");
    lib.defineCMacro("HAVE_VARIADIC_MACROS_C99", "1");
    lib.defineCMacro("HAVE_VARIADIC_MACROS_GCC", "1");
    lib.defineCMacro("OS", "\"Linux\"");
    lib.defineCMacro("RANDOM_FILE", "\"/dev/urandom\"");
    lib.defineCMacro("RECV_TYPE_ARG1", "int");
    lib.defineCMacro("RECV_TYPE_ARG2", "void *");
    lib.defineCMacro("RECV_TYPE_ARG3", "size_t");
    lib.defineCMacro("RECV_TYPE_ARG4", "int");
    lib.defineCMacro("RECV_TYPE_RETV", "ssize_t");
    lib.defineCMacro("SEND_QUAL_ARG2", "const");
    lib.defineCMacro("SEND_TYPE_ARG1", "int");
    lib.defineCMacro("SEND_TYPE_ARG2", "void *");
    lib.defineCMacro("SEND_TYPE_ARG3", "size_t");
    lib.defineCMacro("SEND_TYPE_ARG4", "int");
    lib.defineCMacro("SEND_TYPE_RETV", "ssize_t");
    lib.defineCMacro("SIZEOF_INT", "4");
    lib.defineCMacro("SIZEOF_SHORT", "2");
    lib.defineCMacro("SIZEOF_LONG", "8");
    lib.defineCMacro("SIZEOF_OFF_T", "8");
    lib.defineCMacro("SIZEOF_CURL_OFF_T", "8");
    lib.defineCMacro("SIZEOF_SIZE_T", "8");
    lib.defineCMacro("SIZEOF_TIME_T", "8");
    lib.defineCMacro("STDC_HEADERS", "1");
    lib.defineCMacro("TIME_WITH_SYS_TIME", "1");
    lib.defineCMacro("USE_THREADS_POSIX", "1");
    lib.defineCMacro("USE_UNIX_SOCKETS", null);
    lib.defineCMacro("_FILE_OFFSET_BITS", "64");
    return lib;
}

const srcs = &.{
    "lib/cookie.c",
    "lib/http_chunks.c",
    "lib/escape.c",
    "lib/version_win32.c",
    "lib/url.c",
    "lib/base64.c",
    "lib/mqtt.c",
    "lib/setopt.c",
    "lib/telnet.c",
    "lib/hostip.c",
    "lib/curl_gethostname.c",
    "lib/connect.c",
    "lib/socks_sspi.c",
    "lib/cf-socket.c",
    "lib/curl_fnmatch.c",
    "lib/curl_gssapi.c",
    "lib/http1.c",
    "lib/multi.c",
    "lib/gopher.c",
    "lib/noproxy.c",
    "lib/curl_sasl.c",
    "lib/dict.c",
    "lib/bufref.c",
    "lib/slist.c",
    "lib/curl_trc.c",
    "lib/vtls/rustls.c",
    "lib/vtls/mbedtls.c",
    "lib/vtls/wolfssl.c",
    "lib/vtls/schannel.c",
    "lib/vtls/gtls.c",
    "lib/vtls/sectransp.c",
    "lib/vtls/vtls.c",
    "lib/vtls/mbedtls_threadlock.c",
    "lib/vtls/schannel_verify.c",
    "lib/vtls/hostcheck.c",
    "lib/vtls/bearssl.c",
    "lib/vtls/openssl.c",
    "lib/vtls/x509asn1.c",
    "lib/vtls/keylog.c",
    "lib/file.c",
    "lib/socks_gssapi.c",
    "lib/select.c",
    "lib/socketpair.c",
    "lib/curl_memrchr.c",
    "lib/cfilters.c",
    "lib/strtok.c",
    "lib/version.c",
    "lib/fopen.c",
    "lib/http_aws_sigv4.c",
    "lib/mprintf.c",
    "lib/curl_path.c",
    "lib/parsedate.c",
    "lib/rename.c",
    "lib/ftplistparser.c",
    "lib/content_encoding.c",
    "lib/mime.c",
    "lib/rand.c",
    "lib/curl_des.c",
    "lib/curl_ntlm_core.c",
    "lib/pop3.c",
    "lib/curl_sspi.c",
    "lib/smb.c",
    "lib/conncache.c",
    "lib/inet_pton.c",
    "lib/if2ip.c",
    "lib/openldap.c",
    "lib/http_digest.c",
    "lib/cf-h1-proxy.c",
    "lib/asyn-thread.c",
    "lib/strerror.c",
    "lib/ftp.c",
    "lib/strdup.c",
    "lib/memdebug.c",
    "lib/speedcheck.c",
    "lib/vquic/curl_ngtcp2.c",
    "lib/vquic/curl_msh3.c",
    "lib/vquic/vquic.c",
    "lib/vquic/curl_quiche.c",
    "lib/getinfo.c",
    "lib/http2.c",
    "lib/vauth/oauth2.c",
    "lib/vauth/vauth.c",
    "lib/vauth/digest_sspi.c",
    "lib/vauth/digest.c",
    "lib/vauth/cram.c",
    "lib/vauth/cleartext.c",
    "lib/vauth/krb5_sspi.c",
    "lib/vauth/spnego_sspi.c",
    "lib/vauth/ntlm_sspi.c",
    "lib/vauth/spnego_gssapi.c",
    "lib/vauth/ntlm.c",
    "lib/vauth/krb5_gssapi.c",
    "lib/vauth/gsasl.c",
    "lib/md4.c",
    "lib/bufq.c",
    "lib/curl_get_line.c",
    "lib/hostip4.c",
    "lib/curl_rtmp.c",
    "lib/amigaos.c",
    "lib/share.c",
    "lib/warnless.c",
    "lib/hostsyn.c",
    "lib/md5.c",
    "lib/strtoofft.c",
    "lib/altsvc.c",
    "lib/formdata.c",
    "lib/dynbuf.c",
    "lib/curl_addrinfo.c",
    "lib/hostasyn.c",
    "lib/doh.c",
    "lib/request.c",
    "lib/cw-out.c",
    "lib/curl_sha512_256.c",
    "lib/vtls/cipher_suite.c",
    "lib/easygetopt.c",
    "lib/ldap.c",
    "lib/nonblock.c",
    "lib/idn.c",
    "lib/pingpong.c",
    "lib/imap.c",
    "lib/vssh/libssh.c",
    "lib/vssh/wolfssh.c",
    "lib/vssh/libssh2.c",
    "lib/splay.c",
    "lib/krb5.c",
    "lib/progress.c",
    "lib/cf-haproxy.c",
    "lib/easyoptions.c",
    "lib/curl_range.c",
    "lib/curl_endian.c",
    "lib/http_proxy.c",
    "lib/inet_ntop.c",
    "lib/timeval.c",
    "lib/asyn-ares.c",
    "lib/rtsp.c",
    "lib/sha256.c",
    "lib/curl_threads.c",
    "lib/easy.c",
    "lib/dynhds.c",
    "lib/tftp.c",
    "lib/hsts.c",
    "lib/smtp.c",
    "lib/hash.c",
    "lib/cf-https-connect.c",
    "lib/getenv.c",
    "lib/headers.c",
    "lib/system_win32.c",
    "lib/http_ntlm.c",
    "lib/psl.c",
    "lib/ws.c",
    "lib/hostip6.c",
    "lib/curl_multibyte.c",
    "lib/netrc.c",
    "lib/llist.c",
    "lib/urlapi.c",
    "lib/strcase.c",
    "lib/sendf.c",
    "lib/timediff.c",
    "lib/http.c",
    "lib/cf-h2-proxy.c",
    "lib/socks.c",
    "lib/http_negotiate.c",
    "lib/transfer.c",
    "lib/c-hyper.c",
    "lib/hmac.c",
    "lib/fileinfo.c",
};
