import QtQuick 2.5
import QtQuick.Window 2.2
import org.kde.plasma.core 2.0 as PlasmaCore

Rectangle {
    id: root
    color: "black"

    // Use the real screen size (don’t hardcode 1280x800)
    width: Screen.width
    height: Screen.height

    property int stage

    Component.onCompleted: stage = 2

    // Hide cursor everywhere in the splash (see #2)
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: Qt.BlankCursor
        z: 999999
    }

    Item {
        id: content
        anchors.fill: parent
        opacity: 0

        Image {
            id: logo
            property real size: PlasmaCore.Units.gridUnit * 24

            anchors.centerIn: parent

            // Actually use the size property so the visual center matches expectation
            width: size
            height: size
            fillMode: Image.PreserveAspectFit

            source: "images/deck_logo.svgz"
            sourceSize.width: width
            sourceSize.height: height
        }
    }

    OpacityAnimator {
        id: introAnimation
        running: false
        target: content
        from: 0
        to: 1
        duration: PlasmaCore.Units.veryLongDuration * 2
        easing.type: Easing.InOutQuad
    }

    onStageChanged: {
        if (stage == 2) {
            introAnimation.running = true;
        }
    }
}
