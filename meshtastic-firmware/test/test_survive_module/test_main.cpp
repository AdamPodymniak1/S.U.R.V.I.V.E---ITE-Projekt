#ifndef TEST_SURVIVE_MODULE_H
#define TEST_SURVIVE_MODULE_H

#include <unity.h>
#include "modules/SurviveModule.h"

SurviveModule *surviveModule = nullptr;

void setUp(void)
{
    surviveModule = new SurviveModule();
}

void tearDown(void)
{
    delete surviveModule;
    surviveModule = nullptr;
}

void test_survival_mode_defaults_to_disabled()
{
    TEST_ASSERT_FALSE(surviveModule->isSurvivalMode());
}

void test_enable_survival_mode()
{
    surviveModule->setSurvivalMode(true);
    TEST_ASSERT_TRUE(surviveModule->isSurvivalMode());
    surviveModule->setSurvivalMode(false);
    TEST_ASSERT_FALSE(surviveModule->isSurvivalMode());
}

void test_survival_mode_does_not_suppress_critical_portnums()
{
    surviveModule->setSurvivalMode(true);

    meshtastic_MeshPacket packet;
    memset(&packet, 0, sizeof(packet));
    packet.which_payload_variant = meshtastic_MeshPacket_decoded_tag;
    packet.decoded.portnum = meshtastic_PortNum_ADMIN_APP;

    TEST_ASSERT_FALSE(surviveModule->shouldSuppressPacket(&packet));

    packet.decoded.portnum = meshtastic_PortNum_ROUTING_APP;
    TEST_ASSERT_FALSE(surviveModule->shouldSuppressPacket(&packet));

    packet.decoded.portnum = meshtastic_PortNum_POSITION_APP;
    TEST_ASSERT_FALSE(surviveModule->shouldSuppressPacket(&packet));
}

void test_survival_mode_suppresses_text_messages()
{
    surviveModule->setSurvivalMode(true);

    meshtastic_MeshPacket packet;
    memset(&packet, 0, sizeof(packet));
    packet.which_payload_variant = meshtastic_MeshPacket_decoded_tag;
    packet.decoded.portnum = meshtastic_PortNum_TEXT_MESSAGE_APP;

    TEST_ASSERT_TRUE(surviveModule->shouldSuppressPacket(&packet));
}

int main(int argc, char **argv)
{
    UNITY_BEGIN();
    RUN_TEST(test_survival_mode_defaults_to_disabled);
    RUN_TEST(test_enable_survival_mode);
    RUN_TEST(test_survival_mode_does_not_suppress_critical_portnums);
    RUN_TEST(test_survival_mode_suppresses_text_messages);
    return UNITY_END();
}