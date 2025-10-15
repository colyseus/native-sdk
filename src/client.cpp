#include "colyseus/client.h"
#include "colyseus/protocol.h"
#include <sstream>
#include <rapidjson/document.h>
#include <rapidjson/writer.h>
#include <rapidjson/stringbuffer.h>

#include "colyseus/http.h"

namespace Colyseus
{
    Client::Client(const Settings& settings)
        : settings_(settings),
          transportFactory_(createWebSocketTransport) {
        http_ = std::make_shared<HTTP>(&settings_);
    }

    Client::Client(const Settings& settings, TransportFactory transportFactory)
        : settings_(settings),
          transportFactory_(transportFactory) {
        http_ = std::make_shared<HTTP>(&settings_);
    }

    Client::~Client() {
    }

    void Client::joinOrCreate(const std::string& roomName,
                              const std::map<std::string, std::string>& options,
                              std::function<void(Room*)> onSuccess,
                              std::function<void(int, const std::string&)> onError) {
        createMatchMakeRequest("joinOrCreate", roomName, options, onSuccess, onError);
    }

    void Client::create(const std::string& roomName,
                        const std::map<std::string, std::string>& options,
                        std::function<void(Room*)> onSuccess,
                        std::function<void(int, const std::string&)> onError) {
        createMatchMakeRequest("create", roomName, options, onSuccess, onError);
    }

    void Client::join(const std::string& roomName,
                      const std::map<std::string, std::string>& options,
                      std::function<void(Room*)> onSuccess,
                      std::function<void(int, const std::string&)> onError) {
        createMatchMakeRequest("join", roomName, options, onSuccess, onError);
    }

    void Client::joinById(const std::string& roomId,
                          const std::map<std::string, std::string>& options,
                          std::function<void(Room*)> onSuccess,
                          std::function<void(int, const std::string&)> onError) {
        createMatchMakeRequest("joinById", roomId, options, onSuccess, onError);
    }

    void Client::reconnect(const std::string& reconnectionToken,
                           std::function<void(Room*)> onSuccess,
                           std::function<void(int, const std::string&)> onError) {
        size_t pos = reconnectionToken.find(':');
        if (pos == std::string::npos) {
            onError(-1, "Invalid reconnection token format");
            return;
        }

        std::string roomId = reconnectionToken.substr(0, pos);
        std::string token = reconnectionToken.substr(pos + 1);

        std::map<std::string, std::string> options;
        options["reconnectionToken"] = token;

        createMatchMakeRequest("reconnect", roomId, options, onSuccess, onError);
    }

    std::shared_ptr<HTTP> Client::getHTTP() {
        return http_;
    }

    void Client::createMatchMakeRequest(const std::string& method,
                                        const std::string& roomName,
                                        const std::map<std::string, std::string>& options,
                                        std::function<void(Room*)> onSuccess,
                                        std::function<void(int, const std::string&)> onError) {
        // Convert options to JSON using RapidJSON
        rapidjson::Document doc;
        doc.SetObject();
        auto& allocator = doc.GetAllocator();

        for (const auto& [key, value] : options) {
            rapidjson::Value k(key.c_str(), allocator);
            rapidjson::Value v(value.c_str(), allocator);
            doc.AddMember(k, v, allocator);
        }

        rapidjson::StringBuffer buffer;
        rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
        doc.Accept(writer);
        std::string jsonBody = buffer.GetString();

        std::string path = "matchmake/" + method + "/" + roomName;

        http_->post(path, jsonBody,
            [this, onSuccess, onError](const HTTPResponse& response) {
                try {
                    // Parse JSON response
                    rapidjson::Document doc;
                    doc.Parse(response.body.c_str());

                    if (doc.HasParseError()) {
                        onError(-1, "Failed to parse JSON response");
                        return;
                    }

                    SeatReservation reservation;
                    reservation.sessionId = doc["sessionId"].GetString();

                    if (doc.HasMember("reconnectionToken")) {
                        reservation.reconnectionToken = doc["reconnectionToken"].GetString();
                    }

                    if (doc.HasMember("devMode")) {
                        reservation.devMode = doc["devMode"].GetBool();
                    }

                    if (doc.HasMember("protocol")) {
                        reservation.protocol = doc["protocol"].GetString();
                    }

                    // Parse room data
                    const auto& roomData = doc["room"];
                    reservation.room.roomId = roomData["roomId"].GetString();
                    reservation.room.name = roomData["name"].GetString();
                    reservation.room.processId = roomData["processId"].GetString();

                    if (roomData.HasMember("publicAddress")) {
                        reservation.room.publicAddress = roomData["publicAddress"].GetString();
                    }

                    consumeSeatReservation(reservation, onSuccess, onError);

                } catch (const std::exception& e) {
                    onError(-1, std::string("Failed to parse response: ") + e.what());
                }
            },
            [onError](const HTTPException& error) {
                onError(error.getCode(), error.what());
            }
        );
    }

    void Client::consumeSeatReservation(const SeatReservation& reservation,
                                        std::function<void(Room*)> onSuccess,
                                        std::function<void(int, const std::string&)> onError) {
        // Create Room with transport
        Room* room = new Room(reservation.room.name, transportFactory_);
        room->setRoomId(reservation.room.roomId);
        room->setSessionId(reservation.sessionId);

        // Build WebSocket endpoint
        std::map<std::string, std::string> wsOptions;
        wsOptions["sessionId"] = reservation.sessionId;

        if (!reservation.reconnectionToken.empty()) {
            wsOptions["reconnectionToken"] = reservation.reconnectionToken;
        }

        std::string endpoint = buildRoomEndpoint(reservation.room, wsOptions);

        // Connect room
        room->connect(endpoint,
            [onSuccess, room]() {
                onSuccess(room);
            },
            [onError](int code, const std::string& reason) {
                onError(code, reason);
            }
        );
    }

    std::string Client::buildRoomEndpoint(const SeatReservation::RoomData& room,
                                          const std::map<std::string, std::string>& options) {
        std::string base = settings_.getWebSocketEndpoint();

        std::stringstream ss;
        ss << base << "/" << room.processId << "/" << room.roomId;

        if (!options.empty()) {
            ss << "?";
            bool first = true;
            for (const auto& [key, value] : options) {
                if (!first) ss << "&";
                ss << key << "=" << value;
                first = false;
            }
        }

        return ss.str();
    }
}
