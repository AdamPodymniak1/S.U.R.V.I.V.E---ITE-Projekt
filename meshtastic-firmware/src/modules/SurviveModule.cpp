#include "SurviveModule.h"
#include "MeshService.h"
#include "NodeDB.h"
#include "Router.h"
#include "configuration.h"
#include "main.h"
#include <string.h>

extern NodeDB *nodeDB;
extern MeshService *service;

SurviveModule *surviveModule;

SurviveModule::SurviveModule()
    : SinglePortModule("survive", meshtastic_PortNum_PRIVATE_APP),
      concurrency::OSThread("Survive"),
      survivalMode(false), lastReportSecs(0)
{
    surviveModule = this;
    LOG_INFO("SurviveModule initialized\n");
}

void SurviveModule::setSurvivalMode(bool enabled)
{
    survivalMode = enabled;
    LOG_INFO("Survival mode %s\n", enabled ? "ENABLED" : "DISABLED");
    if (enabled) {
        lastReportSecs = 0; // send an immediate report when toggled on
    }
}

bool SurviveModule::shouldSuppressPacket(const meshtastic_MeshPacket *p) const
{
    if (!survivalMode)
        return false;
    if (!p)
        return false;

    uint8_t portnum = p->decoded.portnum;

    // Always allow routing, admin, position, nodeinfo and our own traffic
    switch (portnum) {
        case meshtastic_PortNum_ROUTING_APP:
        case meshtastic_PortNum_ADMIN_APP:
        case meshtastic_PortNum_POSITION_APP:
        case meshtastic_PortNum_NODEINFO_APP:
        case meshtastic_PortNum_PRIVATE_APP:
            return false;
        default:
            return true;
    }
}

void SurviveModule::sendNodePositionReport(NodeNum dest)
{
    auto nodeNums = nodeDB->snapshotPositionNodeNums(0);
    if (nodeNums.empty()) {
        LOG_DEBUG("No nodes with positions to report\n");
        return;
    }

    // Payload: CSV of "<nodehex>,<lat_i>,<lon_i>,<alt>;" per positioned node
    char payload[200] = "";
    size_t written = 0;

    for (auto num : nodeNums) {
        meshtastic_PositionLite pos;
        if (!nodeDB->copyNodePosition(num, pos))
            continue;
        if (pos.latitude_i == 0 && pos.longitude_i == 0)
            continue;

        int remaining = sizeof(payload) - written - 1;
        int needed = snprintf(nullptr, 0, "%x,%d,%d,%d;", num, pos.latitude_i, pos.longitude_i, pos.altitude);
        if (needed <= 0 || needed >= remaining)
            break;

        written += snprintf(payload + written, remaining, "%x,%d,%d,%d;", num, pos.latitude_i, pos.longitude_i, pos.altitude);
    }

    if (written == 0)
        return;

    LOG_DEBUG("Sending node position report (%d nodes, %d bytes)\n", nodeNums.size(), written);

    meshtastic_MeshPacket *p = router->allocForSending();
    if (!p)
        return;

    p->decoded.portnum = meshtastic_PortNum_PRIVATE_APP;
    p->decoded.payload.size = written;
    memcpy(p->decoded.payload.bytes, payload, written);
    p->to = dest;
    p->want_ack = false;
    p->priority = meshtastic_MeshPacket_Priority_MIN;

    // Last arg = ccToPhone, so the connected phone also gets a copy over BLE.
    service->sendToMesh(p, RX_SRC_LOCAL, true);
}

ProcessMessage SurviveModule::handleReceived(const meshtastic_MeshPacket &mp)
{
    // Any request to the private port triggers a node report back to the sender.
    // The Flutter app sends a single "LOCATE" packet; we answer with the CSV.
    const uint8_t *payload = mp.decoded.payload.bytes;
    uint32_t len = mp.decoded.payload.size;
    bool isLocate = (len == 0) || (len == 6 && strncmp((const char *)payload, "LOCATE", 6) == 0);

    if (isLocate) {
        LOG_INFO("LOCATE request received, sending node positions\n");
        sendNodePositionReport(mp.from);
        return ProcessMessage::STOP;
    }
    return ProcessMessage::CONTINUE;
}

int32_t SurviveModule::runOnce()
{
    uint32_t now = millis() / 1000;
    if (survivalMode && (now - lastReportSecs >= REPORT_INTERVAL_SECS)) {
        lastReportSecs = now;
        sendNodePositionReport();
    }

    return 5000; // check again in 5 seconds
}