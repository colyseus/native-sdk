#pragma once
#include <string>
#include <map>
#include <functional>
#include <memory>

namespace Colyseus {

class Settings;

class HTTPException : public std::exception {
public:
    HTTPException(int code, const std::string& message)
        : code_(code), message_(message) {}

    int getCode() const { return code_; }
    const char* what() const noexcept override { return message_.c_str(); }

private:
    int code_;
    std::string message_;
};

struct HTTPResponse {
    int statusCode;
    std::string body;
    std::map<std::string, std::string> headers;
};

class HTTP {
public:
    HTTP(const Settings* settings);
    ~HTTP();

    // Async requests with callbacks
    void get(const std::string& path,
             std::function<void(const HTTPResponse&)> onSuccess,
             std::function<void(const HTTPException&)> onError,
             const std::map<std::string, std::string>& headers = {});

    void post(const std::string& path,
              const std::string& jsonBody,
              std::function<void(const HTTPResponse&)> onSuccess,
              std::function<void(const HTTPException&)> onError,
              const std::map<std::string, std::string>& headers = {});

    void put(const std::string& path,
             const std::string& jsonBody,
             std::function<void(const HTTPResponse&)> onSuccess,
             std::function<void(const HTTPException&)> onError,
             const std::map<std::string, std::string>& headers = {});

    void del(const std::string& path,
             std::function<void(const HTTPResponse&)> onSuccess,
             std::function<void(const HTTPException&)> onError,
             const std::map<std::string, std::string>& headers = {});

    void setAuthToken(const std::string& token);
    std::string getAuthToken() const;

private:
    const Settings* settings_;
    std::string authToken_;

    void request(const std::string& method,
                 const std::string& path,
                 const std::string& body,
                 std::function<void(const HTTPResponse&)> onSuccess,
                 std::function<void(const HTTPException&)> onError,
                 std::map<std::string, std::string> headers);

    std::string getRequestURL(const std::string& path);
};

}