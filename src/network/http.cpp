#include "colyseus/http.h"
#include "colyseus/settings.h"
#include <curl/curl.h>
#include <sstream>

namespace Colyseus {

// Callback for libcurl to write response data
static size_t WriteCallback(void* contents, size_t size, size_t nmemb, void* userp) {
    ((std::string*)userp)->append((char*)contents, size * nmemb);
    return size * nmemb;
}

HTTP::HTTP(const Settings* settings)
    : settings_(settings) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

HTTP::~HTTP() {
    curl_global_cleanup();
}

void HTTP::get(const std::string& path,
               std::function<void(const HTTPResponse&)> onSuccess,
               std::function<void(const HTTPException&)> onError,
               const std::map<std::string, std::string>& headers) {
    request("GET", path, "", onSuccess, onError, headers);
}

void HTTP::post(const std::string& path,
                const std::string& jsonBody,
                std::function<void(const HTTPResponse&)> onSuccess,
                std::function<void(const HTTPException&)> onError,
                const std::map<std::string, std::string>& headers) {
    request("POST", path, jsonBody, onSuccess, onError, headers);
}

void HTTP::put(const std::string& path,
               const std::string& jsonBody,
               std::function<void(const HTTPResponse&)> onSuccess,
               std::function<void(const HTTPException&)> onError,
               const std::map<std::string, std::string>& headers) {
    request("PUT", path, jsonBody, onSuccess, onError, headers);
}

void HTTP::del(const std::string& path,
               std::function<void(const HTTPResponse&)> onSuccess,
               std::function<void(const HTTPException&)> onError,
               const std::map<std::string, std::string>& headers) {
    request("DELETE", path, "", onSuccess, onError, headers);
}

void HTTP::setAuthToken(const std::string& token) {
    authToken_ = token;
}

std::string HTTP::getAuthToken() const {
    return authToken_;
}

void HTTP::request(const std::string& method,
                   const std::string& path,
                   const std::string& body,
                   std::function<void(const HTTPResponse&)> onSuccess,
                   std::function<void(const HTTPException&)> onError,
                   std::map<std::string, std::string> headers) {

    CURL* curl = curl_easy_init();
    if (!curl) {
        onError(HTTPException(0, "Failed to initialize CURL"));
        return;
    }

    std::string url = getRequestURL(path);
    std::string responseBody;

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &responseBody);

    // Set method
    if (method == "POST") {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    } else if (method == "PUT") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PUT");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    } else if (method == "DELETE") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "DELETE");
    }

    // Set headers
    struct curl_slist* headerList = nullptr;

    // Add custom headers from settings
    for (const auto& [key, value] : settings_->getRequestHeaders()) {
        std::string header = key + ": " + value;
        headerList = curl_slist_append(headerList, header.c_str());
    }

    // Add auth token if present
    if (!authToken_.empty()) {
        std::string authHeader = "Authorization: Bearer " + authToken_;
        headerList = curl_slist_append(headerList, authHeader.c_str());
    }

    // Add additional headers
    for (const auto& [key, value] : headers) {
        std::string header = key + ": " + value;
        headerList = curl_slist_append(headerList, header.c_str());
    }

    // Add content-type for POST/PUT
    if (!body.empty()) {
        headerList = curl_slist_append(headerList, "Content-Type: application/json");
    }

    if (headerList) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headerList);
    }

    // Perform request
    CURLcode res = curl_easy_perform(curl);

    long statusCode = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &statusCode);

    // Cleanup
    if (headerList) {
        curl_slist_free_all(headerList);
    }
    curl_easy_cleanup(curl);

    // Handle response
    if (res != CURLE_OK) {
        onError(HTTPException(0, curl_easy_strerror(res)));
        return;
    }

    if (statusCode >= 400) {
        onError(HTTPException(statusCode, responseBody));
        return;
    }

    HTTPResponse response;
    response.statusCode = statusCode;
    response.body = responseBody;

    onSuccess(response);
}

std::string HTTP::getRequestURL(const std::string& path) {
    std::string base = settings_->getWebRequestEndpoint();

    // Ensure proper path joining
    if (!base.empty() && base.back() == '/' && !path.empty() && path.front() == '/') {
        return base + path.substr(1);
    } else if (!base.empty() && base.back() != '/' && !path.empty() && path.front() != '/') {
        return base + "/" + path;
    }

    return base + path;
}

}