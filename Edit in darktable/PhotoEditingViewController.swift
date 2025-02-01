//
//  PhotoEditingViewController.swift
//  DarktableLauncher
//
//  Created by Aaron Patterson on 2/1/25.
//

import Cocoa
import Photos
import PhotosUI
import os

let EXT_NAME = "dev.tenderlove.DarktableLauncher"
let ADJUSTMENT_DATA_VERSION = "1"
let DARKTABLE_HOME = "/Applications/darktable.app/Contents/MacOS/"
let DARKTABLE_BIN = DARKTABLE_HOME + "darktable"
let DARKTABLE_CLI_BIN = DARKTABLE_HOME + "darktable-cli"

let logger = Logger(subsystem: EXT_NAME, category: "PhotoEditingViewController")

class PhotoEditingViewController: NSViewController, PHContentEditingController {

    var input: PHContentEditingInput?
        var task: Process?
        var imageURL: URL?
        var xmpURL: URL?
        var adjustmentData: PHAdjustmentData?

        override func viewDidLoad() {
            super.viewDidLoad()
                // Do any additional setup after loading the view.
        }

    // MARK: - PHContentEditingController

    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        logger.log("adjustment data \(adjustmentData)")
            if adjustmentData.formatIdentifier == EXT_NAME && adjustmentData.formatVersion == ADJUSTMENT_DATA_VERSION {
                logger.log("we can deal with this adjustment data")
                    self.adjustmentData = adjustmentData
                    return true
            }
        logger.log("unknown adjustment data")
            return false
    }

    func startContentEditing(with contentEditingInput: PHContentEditingInput, placeholderImage: NSImage) {
        if let location = contentEditingInput.fullSizeImageURL {
            let fm = FileManager.default

                // We're going to copy the original asset to a temporary directory.
                // Then open darktable and point it at the file.
                let directory = NSTemporaryDirectory()
                let tempFileComponent = location.lastPathComponent

                if let tempfileURL = NSURL.fileURL(withPathComponents: [directory, tempFileComponent]) {
                    self.imageURL = tempfileURL;
                    do {
                        logger.log("copying file, from: \(location) to: \(tempfileURL)");
                        try fm.copyItem(at: location, to: tempfileURL)
                    } catch {
                        logger.log("couldn't copy")
                    }

                    // Calculate the corresponding XMP file name
                    if let xmpURL = NSURL.fileURL(withPathComponents: [directory, tempFileComponent + ".xmp"]) {
                        self.xmpURL = xmpURL;

                        // If we got adjustment data that we understand, it will
                        // contain the contents of the XMP file.  Write the XMP
                        // file contents out so that darktable has a history of the
                        // edits.
                        if let ad = self.adjustmentData {
                            do {
                                try ad.data.write(to: xmpURL, options: .atomic)
                                    logger.log("wrote to \(xmpURL)")
                            } catch {
                                logger.log("couldn't write to xmp file")
                            }
                        }
                    }

                    // Finally start the darktable process.
                    do {
                        logger.log("starting darktable");
                        let task = Process()
                            task.launchPath = DARKTABLE_BIN
                            task.arguments = ["--library", ":memory:", tempfileURL.path]
                            task.terminationHandler = { _ in
                                // When the process exits, set the "input" field so
                                // that the `finishContentEditing` callback knows that
                                // the process has finished.
                                self.input = contentEditingInput;
                            }
                        try task.run()
                    } catch {
                        logger.log("couldn't start tle task")
                    }
                }

        }
    }

    func finishContentEditing(completionHandler: @escaping ((PHContentEditingOutput?) -> Void)) {
        // Render and provide output on a background queue.
        DispatchQueue.global().async {
            // If the input pointer is available, we know darktable closed.
            if let input = self.input {
                logger.log("we did it!")

                    let directory = NSTemporaryDirectory()
                    let fm = FileManager.default

                    let output = PHContentEditingOutput(contentEditingInput: input)

                    // First, render a JPG from the XML file that Photos can use.
                    let task = Process()
                    task.launchPath = DARKTABLE_CLI_BIN
                    task.arguments = [self.imageURL!.path, self.xmpURL!.path, directory]
                    do {
                        try task.run()
                            task.waitUntilExit()
                    } catch {
                        logger.log("couldn't launch process")
                            return
                    }

                // Second, move the rendered JPG to the location that Photos wants
                if let imageURL = self.imageURL {
                    // Move the output JPG to the expected location
                    do {
                        let jpgURL = imageURL.deletingPathExtension().appendingPathExtension("jpg")
                            try fm.moveItem(at: jpgURL, to: output.renderedContentURL)
                    } catch {
                        logger.log("couldn't move file")
                    }

                    // Clean up the image we copied
                    do {
                        try fm.removeItem(at: imageURL)
                    } catch {
                        logger.log("couldn't delete image symlink")
                    }
                }

                if let it = self.xmpURL {
                    logger.log("it's done \(it.path)")
                        // Read the XMP file and put its contents in to the
                        // adjustmentData metadata object.
                        if let xmpData = try? Data(contentsOf: it) {
                            logger.log("got data \(xmpData)")
                                let adjustmentData = PHAdjustmentData(formatIdentifier: EXT_NAME, formatVersion: ADJUSTMENT_DATA_VERSION, data: xmpData)
                                output.adjustmentData = adjustmentData
                        }

                    // Remove the XMP file
                    do {
                        try fm.removeItem(at: it)
                    } catch {
                        logger.log("couldn't delete xmp file")
                    }
                }

                // Tell everyone we've finished
                completionHandler(output)
            }
        }
    }

    var shouldShowCancelConfirmation: Bool {
        // Determines whether a confirmation to discard changes should be shown to the user on cancel.
        // (Typically, this should be "true" if there are any unsaved changes.)
        return false
    }

    func cancelContentEditing() {
        // Clean up temporary files, etc.
        // May be called after finishContentEditingWithCompletionHandler: while you prepare output.
    }

}
